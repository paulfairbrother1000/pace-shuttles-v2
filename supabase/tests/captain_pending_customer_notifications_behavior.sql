begin;

do $$
declare
  v_booking_id uuid;
  v_departure_id uuid;
  v_as_of timestamptz;
  v_count integer;
begin
  select b.id,d.id,greatest(d.scheduled_departure_ts-interval '23 hours 59 minutes',now())
  into v_booking_id,v_departure_id,v_as_of
  from pace_v2.bookings b
  join pace_v2.departures d on d.id=b.departure_id and d.status='at_risk'
  join pace_v2.booking_allocations ba on ba.booking_id=b.id and ba.status in ('preliminary','confirmed') and ba.seats=b.seats
  join pace_v2.vehicle_considerations vc on vc.id=ba.vehicle_consideration_id and vc.departure_id=d.id and vc.status='under_consideration'
  join pace_v2.vehicles v on v.id=vc.vehicle_id and v.active
  join pace_v2.vehicle_types vt on vt.id=v.vehicle_type_id and vt.active
  join pace_v2.routes r on r.id=d.route_id
  join pace_v2.countries c on c.id=r.country_id and nullif(trim(c.timezone),'') is not null
  join pace_v2.pickup_points pp on pp.id=r.pickup_id and pace_v2.is_valid_t24_directions_url(pp.directions_url)
  join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id) and pace_v2.is_valid_customer_notification_email(u.email)
  where d.scheduled_departure_ts>now()
    and exists(select 1 from pace_v2.allocation_decisions ad where ad.departure_id=d.id and ad.decision_reason_code='T24_INSUFFICIENT_CAPTAINS')
  order by b.id
  limit 1;

  if v_booking_id is null then
    raise exception 'fixture: future at-risk captain-shortage booking required';
  end if;

  delete from pace_v2.notifications
  where booking_id=v_booking_id and departure_id=v_departure_id
    and template_code in ('journey_captain_pending','journey_tomorrow');

  perform public.v2_system_schedule_t24_journey_notifications(v_as_of);
  if not exists(
    select 1 from pace_v2.notifications
    where booking_id=v_booking_id and departure_id=v_departure_id
      and template_code='journey_captain_pending'
      and metadata->>'captain_status'='to_be_confirmed'
  ) then raise exception 'captain pending notification was not queued'; end if;

  perform public.v2_system_schedule_t24_journey_notifications(v_as_of+interval '1 minute');
  select count(*) into v_count from pace_v2.notifications
  where booking_id=v_booking_id and departure_id=v_departure_id and template_code='journey_captain_pending';
  if v_count<>1 then raise exception 'captain pending notification duplicated'; end if;

  if not exists(
    select 1 from pace_v2.operational_alerts
    where exception_key='t24_details_overdue:'||v_booking_id::text and resolved_at is null
  ) then raise exception 'captain shortage alert was incorrectly resolved'; end if;

  insert into pace_v2.notifications(booking_id,departure_id,to_email,template_code,subject,body,status,scheduled_at)
  select v_booking_id,v_departure_id,u.email,'journey_tomorrow','Final journey confirmation','Final journey confirmation','queued',v_as_of
  from auth.users u where u.id=pace_v2.booking_owner_user_id(v_booking_id)
  on conflict (booking_id,template_code) where template_code='journey_tomorrow' do nothing;

  if (select count(distinct template_code) from pace_v2.notifications
      where booking_id=v_booking_id and departure_id=v_departure_id
        and template_code in ('journey_captain_pending','journey_tomorrow'))<>2
  then raise exception 'final journey notification was suppressed by captain pending notification'; end if;
end $$;

rollback;
