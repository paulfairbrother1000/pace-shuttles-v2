-- Pace journeys are sold as returns.  Derive the operational return pickup
-- from the first leg's planned arrival plus three hours, rounded down to the
-- start of that hour.  The date component is deliberately discarded because
-- service return designs store a local wall-clock time; the backfill below
-- rejects any design that would cross the service day.
create or replace function pace_v2.default_return_local_time(
  p_departure_time time,
  p_duration_minutes integer
)
returns time
language plpgsql
immutable
security definer
set search_path=''
as $$
begin
  if p_departure_time is null or p_duration_minutes is null or p_duration_minutes<=0 then
    raise exception using
      errcode='22023',
      message='departure time and positive journey duration are required';
  end if;

  return date_trunc(
    'hour',
    timestamp '2000-01-01'+p_departure_time
      +make_interval(mins=>p_duration_minutes+180)
  )::time;
end
$$;

revoke all on function pace_v2.default_return_local_time(time,integer)
  from public,anon,authenticated,service_role;

-- St John's to Prickly Pear was the only active route without a duration.
-- Thirty minutes is the approved operational fallback and is also safe for a
-- future active route that has been created without its duration populated.
update pace_v2.routes route
set approx_duration_mins=30,
    updated_at=now()
where route.is_active
  and route.approx_duration_mins is null
  and exists(
    select 1
    from pace_v2.services service
    where service.route_id=route.id
      and service.active
  );

-- A reverse route uses an operational pickup cloned from the public
-- destination and an unpublished destination cloned from the public pickup.
-- Stable v1_source_id markers make this migration idempotent without relying
-- on generated UUIDs.
insert into pace_v2.pickup_points(
  country_id,name,address1,address2,town,region,postal_code,picture_url,
  description,arrival_notes,directions_url,active,region_id,locality_id,
  latitude,longitude,sort_order,v1_source_id
)
select distinct on(destination.id)
  destination.country_id,
  destination.name,
  destination.address1,
  destination.address2,
  destination.town,
  destination.region,
  destination.postal_code,
  destination.picture_url,
  destination.description,
  destination.arrival_notes,
  destination.directions_url,
  true,
  destination.region_id,
  destination.locality_id,
  destination.latitude,
  destination.longitude,
  destination.sort_order,
  'pace-v2:return-pickup:'||destination.id::text
from pace_v2.services service
join pace_v2.routes route
  on route.id=service.route_id
 and route.is_active
join pace_v2.destinations destination
  on destination.id=route.destination_id
where service.active
  and not exists(
    select 1
    from pace_v2.pickup_points existing
    where existing.v1_source_id='pace-v2:return-pickup:'||destination.id::text
  )
order by destination.id;

insert into pace_v2.destinations(
  country_id,name,address1,address2,town,region,postal_code,picture_url,
  description,destination_type,wet_or_dry,arrival_notes,directions_url,
  region_id,locality_id,latitude,longitude,active,sort_order,v1_source_id,
  published_at,published_by
)
select distinct on(pickup.id)
  pickup.country_id,
  pickup.name,
  pickup.address1,
  pickup.address2,
  pickup.town,
  pickup.region,
  pickup.postal_code,
  pickup.picture_url,
  pickup.description,
  'Operational return',
  'dry',
  pickup.arrival_notes,
  pickup.directions_url,
  pickup.region_id,
  pickup.locality_id,
  pickup.latitude,
  pickup.longitude,
  true,
  pickup.sort_order,
  'pace-v2:return-destination:'||pickup.id::text,
  null,
  null
from pace_v2.services service
join pace_v2.routes route
  on route.id=service.route_id
 and route.is_active
join pace_v2.pickup_points pickup
  on pickup.id=route.pickup_id
where service.active
  and not exists(
    select 1
    from pace_v2.destinations existing
    where existing.v1_source_id='pace-v2:return-destination:'||pickup.id::text
  )
order by pickup.id;

insert into pace_v2.routes(
  route_name,name,frequency,pickup_time,approx_duration_mins,
  approximate_distance_miles,picture_url,season_from,season_to,
  trip_timezone,pickup_id,destination_id,country_id,is_active,market_id,
  region_id,locality_id,display_description,booking_lead_time_hours,
  v1_source_id,t72_hours,t24_hours
)
select distinct on(outbound.id)
  destination.name||' → '||pickup.name,
  destination.name||' → '||pickup.name,
  outbound.frequency,
  null,
  outbound.approx_duration_mins,
  outbound.approximate_distance_miles,
  outbound.picture_url,
  outbound.season_from,
  outbound.season_to,
  outbound.trip_timezone,
  reverse_pickup.id,
  reverse_destination.id,
  outbound.country_id,
  true,
  outbound.market_id,
  outbound.region_id,
  outbound.locality_id,
  'Operational return route for '||coalesce(outbound.route_name,outbound.name),
  outbound.booking_lead_time_hours,
  'pace-v2:return-route:'||outbound.id::text,
  outbound.t72_hours,
  outbound.t24_hours
from pace_v2.services service
join pace_v2.routes outbound
  on outbound.id=service.route_id
 and outbound.is_active
join pace_v2.pickup_points pickup on pickup.id=outbound.pickup_id
join pace_v2.destinations destination on destination.id=outbound.destination_id
join pace_v2.pickup_points reverse_pickup
  on reverse_pickup.v1_source_id='pace-v2:return-pickup:'||destination.id::text
join pace_v2.destinations reverse_destination
  on reverse_destination.v1_source_id='pace-v2:return-destination:'||pickup.id::text
where service.active
  and not exists(
    select 1
    from pace_v2.routes existing
    where existing.v1_source_id='pace-v2:return-route:'||outbound.id::text
  )
order by outbound.id;

-- Each outbound route owns a distinct generated reverse route.  The admin
-- lifecycle trigger intentionally blocks non-UI mutation, so it is disabled
-- only for this bounded migration statement and restored immediately.
alter table pace_v2.route_return_mappings
  disable trigger route_return_mappings_admin_mutation;

insert into pace_v2.route_return_mappings(outbound_route_id,return_route_id)
select distinct outbound.id,reverse_route.id
from pace_v2.services service
join pace_v2.routes outbound
  on outbound.id=service.route_id
 and outbound.is_active
join pace_v2.routes reverse_route
  on reverse_route.v1_source_id='pace-v2:return-route:'||outbound.id::text
where service.active
on conflict(outbound_route_id) do nothing;

alter table pace_v2.route_return_mappings
  enable trigger route_return_mappings_admin_mutation;

insert into pace_v2.route_vehicle_types(
  route_id,vehicle_type_id,active,effective_from,effective_to
)
select
  mapping.return_route_id,
  permitted.vehicle_type_id,
  permitted.active,
  permitted.effective_from,
  permitted.effective_to
from pace_v2.route_return_mappings mapping
join pace_v2.services service
  on service.route_id=mapping.outbound_route_id
 and service.active
join pace_v2.route_vehicle_types permitted
  on permitted.route_id=mapping.outbound_route_id
where not exists(
  select 1
  from pace_v2.route_vehicle_types existing
  where existing.route_id=mapping.return_route_id
    and existing.vehicle_type_id=permitted.vehicle_type_id
);

insert into pace_v2.service_return_designs(
  service_id,reverse_route_id,return_local_time,return_duration_minutes
)
select
  service.id,
  mapping.return_route_id,
  pace_v2.default_return_local_time(
    service.departure_time,
    outbound.approx_duration_mins
  ),
  outbound.approx_duration_mins
from pace_v2.services service
join pace_v2.routes outbound
  on outbound.id=service.route_id
 and outbound.is_active
join pace_v2.route_return_mappings mapping
  on mapping.outbound_route_id=outbound.id
where service.active
on conflict(service_id) do nothing;

-- Existing protected departures cannot go through the normal editor path.
-- Pair every future non-terminal commercial service occurrence in place,
-- preserving the outbound departure, booking and allocation identities.
create or replace function pace_v2.backfill_default_return_journeys(
  p_limit integer default 100
)
returns integer
language plpgsql
security definer
set search_path=''
as $$
declare
  candidate record;
  v_return_id uuid;
  v_pair_id uuid;
  v_return_ts timestamptz;
  v_count integer:=0;
begin
  if p_limit is null or p_limit<1 or p_limit>250 then
    raise exception using errcode='22023',message='backfill limit must be between 1 and 250';
  end if;

  set constraints all deferred;
  perform set_config('pace_v2.journey_pair_mutation_authorized','on',true);

  for candidate in
    select
      departure.id as outbound_id,
      departure.service_id,
      departure.local_departure_date,
      departure.scheduled_arrival_ts,
      design.return_local_time,
      design.return_duration_minutes,
      reverse_route.id as reverse_route_id,
      reverse_route.trip_timezone,
      reverse_route.t72_hours,
      reverse_route.t24_hours
    from pace_v2.departures departure
    join pace_v2.services service
      on service.id=departure.service_id
     and service.active
    join pace_v2.service_return_designs design
      on design.service_id=service.id
    join pace_v2.routes reverse_route
      on reverse_route.id=design.reverse_route_id
     and reverse_route.is_active
    where departure.is_commercial
      and departure.journey_pair_id is null
      and departure.scheduled_departure_ts>now()
      and departure.status not in('cancelled','completed')
    order by departure.scheduled_departure_ts,departure.id
    limit p_limit
    for update of departure skip locked
  loop
    v_return_ts:=(candidate.local_departure_date::timestamp+candidate.return_local_time)
      at time zone candidate.trip_timezone;

    if v_return_ts<=candidate.scheduled_arrival_ts then
      raise exception using
        errcode='22023',
        message='default return time must be after the outbound arrival';
    end if;

    insert into pace_v2.departures(
      service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
      trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial
    )
    values(
      candidate.service_id,
      candidate.reverse_route_id,
      v_return_ts,
      v_return_ts+make_interval(mins=>candidate.return_duration_minutes),
      candidate.trip_timezone,
      candidate.local_departure_date,
      v_return_ts-make_interval(hours=>coalesce(candidate.t72_hours,72)),
      v_return_ts-make_interval(hours=>coalesce(candidate.t24_hours,24)),
      'scheduled',
      false
    )
    returning id into v_return_id;

    insert into pace_v2.journey_pairs(outbound_departure_id,return_departure_id)
    values(candidate.outbound_id,v_return_id)
    returning id into v_pair_id;

    update pace_v2.departures
    set journey_pair_id=v_pair_id,
        leg_number=case when id=candidate.outbound_id then 1 else 2 end
    where id in(candidate.outbound_id,v_return_id);

    v_count:=v_count+1;
  end loop;

  perform set_config('pace_v2.journey_pair_mutation_authorized','off',true);
  return v_count;
end
$$;

revoke all on function pace_v2.backfill_default_return_journeys(integer)
  from public,anon,authenticated,service_role;

-- Pair the earliest occurrences first so today's and tomorrow's journeys are
-- complete before their customer reminders are regenerated.  Older generated
-- inventory is completed in bounded follow-up transactions.
do $initial_return_backfill$
begin
  perform pace_v2.backfill_default_return_journeys(100);
end
$initial_return_backfill$;

do $verify_backfill$
begin
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
    raise exception 'every active service must have a return design';
  end if;

  if exists(
    select 1
    from pace_v2.departures departure
    join pace_v2.services service
      on service.id=departure.service_id
     and service.active
    where departure.is_commercial
      and departure.scheduled_departure_ts>now()
      and departure.scheduled_departure_ts<now()+interval '48 hours'
      and departure.status not in('cancelled','completed')
      and departure.journey_pair_id is null
  ) then
    raise exception 'every departure in the next 48 hours must have a return pairing';
  end if;

  if exists(
    select 1
    from pace_v2.service_return_designs design
    join pace_v2.services service on service.id=design.service_id
    join pace_v2.routes outbound on outbound.id=service.route_id
    where service.active
      and (
        design.return_duration_minutes is distinct from outbound.approx_duration_mins
        or design.return_local_time is distinct from
          pace_v2.default_return_local_time(
            service.departure_time,
            outbound.approx_duration_mins
          )
      )
  ) then
    raise exception 'default return designs must use the approved timing rule';
  end if;
end
$verify_backfill$;

-- Extending the duty through Leg 2 must not create a captain conflict.  Abort
-- atomically if live assignments have changed since the preflight check.
do $verify_captain_windows$
begin
  if exists(
    select 1
    from pace_v2.captain_duty_reservations first_reservation
    cross join lateral pace_v2.captain_duty_resource_window(
      first_reservation.departure_id
    ) first_window
    join pace_v2.captain_duty_reservations second_reservation
      on second_reservation.captain_id=first_reservation.captain_id
     and second_reservation.id>first_reservation.id
     and second_reservation.state in('provisional','held_t72','confirmed_t24')
    cross join lateral pace_v2.captain_duty_resource_window(
      second_reservation.departure_id
    ) second_window
    where first_reservation.state in('provisional','held_t72','confirmed_t24')
      and tstzrange(
        first_window.scheduled_start_ts,
        first_window.scheduled_end_ts,
        '[)'
      ) && tstzrange(
        second_window.scheduled_start_ts,
        second_window.scheduled_end_ts,
        '[)'
      )
  ) then
    raise exception using
      errcode='23P01',
      message='return journey backfill would overlap an active captain duty';
  end if;
end
$verify_captain_windows$;

with canonical_windows as (
  select
    reservation.id,
    resource.scheduled_start_ts,
    resource.scheduled_end_ts
  from pace_v2.captain_duty_reservations reservation
  cross join lateral pace_v2.captain_duty_resource_window(
    reservation.departure_id
  ) resource
  where reservation.state in('provisional','held_t72','confirmed_t24')
)
update pace_v2.captain_duty_reservations reservation
set duty_start_ts=canonical.scheduled_start_ts,
    duty_end_ts=canonical.scheduled_end_ts
from canonical_windows canonical
where reservation.id=canonical.id
  and (
    reservation.duty_start_ts is distinct from canonical.scheduled_start_ts
    or reservation.duty_end_ts is distinct from canonical.scheduled_end_ts
  );

-- Fail closed at the notification table boundary.  This protects every
-- producer, including an older scheduler implementation, from ever queuing a
-- one-way T-24 reminder for a product that is always sold as a return.
create or replace function pace_v2.require_return_pairing_for_t24_notification()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if new.template_code='journey_tomorrow'
     and new.status in('queued','sending')
     and not exists(
       select 1
       from pace_v2.journey_pairs pair
       where pair.outbound_departure_id=new.departure_id
     ) then
    insert into pace_v2.operational_alerts(
      exception_key,exception_type,severity,booking_id,departure_id,details
    )
    values(
      't24_return_pairing_missing:'||new.booking_id::text,
      't24_details_overdue',
      'high',
      new.booking_id,
      new.departure_id,
      jsonb_build_object(
        'missing',jsonb_build_array('return journey pairing'),
        'attempted_at',now()
      )
    )
    on conflict(exception_key) where resolved_at is null do update
      set severity='high',
          details=excluded.details,
          detected_at=excluded.detected_at;
    return null;
  end if;

  if new.template_code='journey_tomorrow' then
    update pace_v2.operational_alerts
    set resolved_at=now(),
        resolution_note='Return journey paired; T-24 reminder queued'
    where exception_key='t24_return_pairing_missing:'||new.booking_id::text
      and resolved_at is null;
  end if;

  return new;
end
$$;

revoke all on function pace_v2.require_return_pairing_for_t24_notification()
  from public,anon,authenticated,service_role;

drop trigger if exists notifications_require_return_pairing_for_t24
  on pace_v2.notifications;
create trigger notifications_require_return_pairing_for_t24
before insert or update of template_code,departure_id,status
on pace_v2.notifications
for each row
execute function pace_v2.require_return_pairing_for_t24_notification();

-- Replace only the deliberately held, unsent reminders.  The scheduler now
-- sees authoritative pairs and regenerates the approved two-leg itinerary.
delete from pace_v2.notifications notification
where notification.template_code='journey_tomorrow'
  and notification.status='queued'
  and notification.metadata->>'dispatch_hold'=
    'missing_authoritative_return_configuration'
  and exists(
    select 1
    from pace_v2.journey_pairs pair
    where pair.outbound_departure_id=notification.departure_id
  );

do $release_correct_t24$
begin
  perform public.v2_system_schedule_t24_journey_notifications(now());
end
$release_correct_t24$;

comment on function pace_v2.default_return_local_time(time,integer) is
  'Returns Leg 1 arrival plus three hours rounded down to the whole hour.';
comment on function pace_v2.require_return_pairing_for_t24_notification() is
  'Prevents a T-24 customer reminder from being queued without an authoritative return leg.';
