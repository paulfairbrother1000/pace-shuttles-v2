begin;

do $$
begin
  if pace_v2.default_return_local_time('10:00'::time,20)<>'13:00'::time then
    raise exception '10:00 plus 20 minutes plus three hours must floor to 13:00';
  end if;
  if pace_v2.default_return_local_time('10:30'::time,77)<>'14:00'::time then
    raise exception '10:30 plus 77 minutes plus three hours must floor to 14:00';
  end if;
  if pace_v2.default_return_local_time('10:30'::time,30)<>'14:00'::time then
    raise exception 'an exact whole-hour return must remain on that hour';
  end if;

  if has_function_privilege(
    'authenticated',
    'pace_v2.default_return_local_time(time without time zone,integer)',
    'execute'
  ) then
    raise exception 'default return timing helper must remain private';
  end if;

  if exists(
    select 1
    from pace_v2.services service
    where service.active
      and not exists(
        select 1
        from pace_v2.service_return_designs design
        where design.service_id=service.id
      )
  ) then
    raise exception 'an active service is missing its return design';
  end if;

  if exists(
    select 1
    from pace_v2.departures departure
    join pace_v2.services service
      on service.id=departure.service_id
     and service.active
    where departure.is_commercial
      and departure.scheduled_departure_ts>now()
      and departure.status not in('cancelled','completed')
      and departure.journey_pair_id is null
  ) then
    raise exception 'a future active departure is missing its return leg';
  end if;

  if exists(
    select 1
    from pace_v2.captain_duty_reservations reservation
    cross join lateral pace_v2.captain_duty_resource_window(
      reservation.departure_id
    ) resource
    where reservation.state in('provisional','held_t72','confirmed_t24')
      and (
        reservation.duty_start_ts is distinct from resource.scheduled_start_ts
        or reservation.duty_end_ts is distinct from resource.scheduled_end_ts
      )
  ) then
    raise exception 'an active captain reservation does not span the paired duty';
  end if;
end
$$;

do $t24_pairing_guard$
declare
  fixture record;
  v_unpaired_id uuid:=gen_random_uuid();
begin
  select
    booking.id as booking_id,
    departure.service_id,
    departure.route_id,
    departure.trip_timezone
  into fixture
  from pace_v2.bookings booking
  join pace_v2.departures departure on departure.id=booking.departure_id
  limit 1;

  if fixture.booking_id is null then
    raise exception 'fixture booking required for the T-24 pairing guard';
  end if;

  insert into pace_v2.departures(
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
    trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial
  )
  values(
    v_unpaired_id,
    fixture.service_id,
    fixture.route_id,
    '2098-01-01 12:00:00+00',
    '2098-01-01 13:00:00+00',
    fixture.trip_timezone,
    '2098-01-01',
    '2097-12-29 12:00:00+00',
    '2097-12-31 12:00:00+00',
    'scheduled',
    false
  );

  delete from pace_v2.notifications
  where booking_id=fixture.booking_id
    and template_code='journey_tomorrow';

  delete from pace_v2.operational_alerts
  where exception_key='t24_return_pairing_missing:'||fixture.booking_id::text;

  insert into pace_v2.notifications(
    booking_id,departure_id,to_email,template_code,subject,body,status,scheduled_at
  )
  values(
    fixture.booking_id,v_unpaired_id,'fixture@example.com','journey_tomorrow',
    'must not queue','must not queue','queued',now()
  );

  if exists(
    select 1
    from pace_v2.notifications
    where booking_id=fixture.booking_id
      and departure_id=v_unpaired_id
      and template_code='journey_tomorrow'
  ) then
    raise exception 'an unpaired T-24 reminder passed the fail-closed guard';
  end if;

  if not exists(
    select 1
    from pace_v2.operational_alerts
    where exception_key='t24_return_pairing_missing:'||fixture.booking_id::text
      and resolved_at is null
      and (details->'missing') ? 'return journey pairing'
  ) then
    raise exception 'the blocked unpaired reminder did not raise an alert';
  end if;
end
$t24_pairing_guard$;

rollback;
