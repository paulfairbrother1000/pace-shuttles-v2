begin;

do $$
declare
  v_scheduler regprocedure:='public.v2_system_schedule_t24_journey_notifications(timestamp with time zone)'::regprocedure;
begin
  if v_scheduler is null then raise exception 'T-24 scheduler missing'; end if;
  if has_function_privilege('anon',v_scheduler,'execute') or has_function_privilege('authenticated',v_scheduler,'execute') then
    raise exception 'T-24 scheduler must not be client executable';
  end if;
  if not exists(select 1 from pg_indexes where schemaname='pace_v2' and indexname='customer_notifications_one_journey_tomorrow_per_booking') then
    raise exception 'T-24 booking/template de-duplication missing';
  end if;
  if not exists(select 1 from information_schema.columns where table_schema='pace_v2' and table_name='notifications' and column_name='metadata') then
    raise exception 'notification lateness metadata missing';
  end if;
end $$;

do $$
declare
  v_booking_id uuid; v_departure_id uuid; v_pickup_id uuid; v_captain_id uuid; v_as_of timestamptz:='2030-01-01 12:00:00+00';
  v_original_directions text; v_original_first_name text; v_original_last_name text; v_count integer; v_late integer; v_bad_directions text;
begin
  select b.id,d.id,pp.id,cap.id into v_booking_id,v_departure_id,v_pickup_id,v_captain_id
  from pace_v2.bookings b
  join pace_v2.orders o on o.id=b.order_id
  join pace_v2.booking_allocations ba on ba.booking_id=b.id
  join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status='confirmed'
  join pace_v2.departures d on d.id=ca.departure_id
  join pace_v2.routes r on r.id=d.route_id
  join pace_v2.countries c on c.id=r.country_id and nullif(trim(c.timezone),'') is not null
  join pg_timezone_names tz on tz.name=c.timezone
  join pace_v2.pickup_points pp on pp.id=r.pickup_id
  join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active and nullif(trim(v.name),'') is not null
  join pace_v2.vehicle_types vt on vt.id=v.vehicle_type_id and vt.active and nullif(trim(vt.name),'') is not null
  join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id and nullif(trim(cap.first_name),'') is not null and nullif(trim(cap.last_name),'') is not null
  join pace_v2.captain_vehicle_types cvt on cvt.captain_id=cap.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
  join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id) and nullif(trim(u.email),'') is not null
  where lower(coalesce(to_jsonb(o)->>'payment_status',to_jsonb(o)->>'status','')) in ('paid','succeeded','complete','completed')
    and lower(coalesce(to_jsonb(b)->>'status','active')) not in ('cancelled','canceled','refunded','inactive')
    and d.status not in ('cancelled','completed')
    and (select count(distinct a2.id) from pace_v2.captain_assignments a2 join pace_v2.captains cap2 on cap2.id=a2.captain_id and cap2.active and cap2.operator_id=ca.operator_id join pace_v2.captain_vehicle_types cvt2 on cvt2.captain_id=cap2.id and cvt2.vehicle_type_id=v.vehicle_type_id and cvt2.active where a2.confirmed_allocation_id=ca.id and a2.active)=1
  order by b.id,ca.id,a.id limit 1;
  if v_booking_id is null then raise exception 'fixture: paid allocated booking with party-leader email required'; end if;

  select directions_url into v_original_directions from pace_v2.pickup_points where id=v_pickup_id;
  select first_name,last_name into v_original_first_name,v_original_last_name from pace_v2.captains where id=v_captain_id;
  update pace_v2.bookings set customer_name='Paul Leader' where id=v_booking_id;
  update pace_v2.pickup_points set directions_url='https://maps.app.goo.gl/t24fixture' where id=v_pickup_id;
  update pace_v2.departures set scheduled_departure_ts=v_as_of+interval '24 hours',scheduled_arrival_ts=v_as_of+interval '26 hours' where id=v_departure_id;
  delete from pace_v2.notifications where booking_id=v_booking_id and template_code='journey_tomorrow';
  delete from pace_v2.operational_alerts where exception_key='t24_details_overdue:'||v_booking_id::text;

  if not pace_v2.is_valid_t24_directions_url('https://maps.app.goo.gl/t24fixture') or not pace_v2.is_valid_t24_directions_url('https://www.google.com/maps/place/test') or pace_v2.is_valid_t24_directions_url('https://google.com.evil/maps') or pace_v2.is_valid_t24_directions_url('https://maps.google.invalid/path') then raise exception 'directions URL allowlist accepted a counterfeit or rejected a valid Google Maps host'; end if;
  perform public.v2_system_schedule_t24_journey_notifications(v_as_of-interval '1 second');
  if exists(select 1 from pace_v2.notifications where booking_id=v_booking_id and template_code='journey_tomorrow') or exists(select 1 from pace_v2.operational_alerts where exception_key='t24_details_overdue:'||v_booking_id::text and resolved_at is null) then raise exception 'T-24 queued or alerted before its due time'; end if;
  perform public.v2_system_schedule_t24_journey_notifications(v_as_of);
  perform public.v2_system_schedule_t24_journey_notifications(v_as_of);
  select count(*) into v_count from pace_v2.notifications where booking_id=v_booking_id and template_code='journey_tomorrow';
  if v_count<>1 then raise exception 'T-24 duplicate prevention failed: expected 1 queue row, got %',v_count; end if;

  delete from pace_v2.notifications where booking_id=v_booking_id and template_code='journey_tomorrow';
  foreach v_bad_directions in array array['http://example.com/not-google','https://google.com.evil/maps','https://maps.google.invalid/path'] loop
    update pace_v2.pickup_points set directions_url=v_bad_directions where id=v_pickup_id;
    perform public.v2_system_schedule_t24_journey_notifications(v_as_of+interval '10 minutes');
    if exists(select 1 from pace_v2.notifications where booking_id=v_booking_id and template_code='journey_tomorrow') then raise exception 'malformed directions queued T-24 email: %',v_bad_directions; end if;
    if not exists(select 1 from pace_v2.operational_alerts where exception_key='t24_details_overdue:'||v_booking_id::text and resolved_at is null) then raise exception 'malformed directions did not create open t24_details_overdue alert: %',v_bad_directions; end if;
  end loop;

  update pace_v2.pickup_points set directions_url='https://maps.app.goo.gl/t24fixture' where id=v_pickup_id;
  perform public.v2_system_schedule_t24_journey_notifications(v_as_of+interval '30 minutes');
  if not exists(select 1 from pace_v2.notifications where booking_id=v_booking_id and template_code='journey_tomorrow') then raise exception 'late correction did not queue a notification'; end if;
  select (metadata->>'minutes_late')::integer into v_late from pace_v2.notifications where booking_id=v_booking_id and template_code='journey_tomorrow';
  if v_late is distinct from 30 then raise exception 'late correction did not record 30 minutes_late: %',v_late; end if;
  if exists(select 1 from pace_v2.operational_alerts where exception_key='t24_details_overdue:'||v_booking_id::text and resolved_at is null) then raise exception 'corrected T-24 details did not resolve alert'; end if;

  delete from pace_v2.notifications where booking_id=v_booking_id and template_code='journey_tomorrow';
  update pace_v2.captains set first_name='' where id=v_captain_id;
  perform public.v2_system_schedule_t24_journey_notifications(v_as_of+interval '40 minutes');
  if exists(select 1 from pace_v2.notifications where booking_id=v_booking_id and template_code='journey_tomorrow') or not exists(select 1 from pace_v2.operational_alerts where exception_key='t24_details_overdue:'||v_booking_id::text and (details->'missing') ? 'missing captain first name' and resolved_at is null) then raise exception 'missing captain first name was not withheld and alerted'; end if;

  update pace_v2.captains set first_name=v_original_first_name,last_name='' where id=v_captain_id;
  perform public.v2_system_schedule_t24_journey_notifications(v_as_of+interval '50 minutes');
  if exists(select 1 from pace_v2.notifications where booking_id=v_booking_id and template_code='journey_tomorrow') or not exists(select 1 from pace_v2.operational_alerts where exception_key='t24_details_overdue:'||v_booking_id::text and (details->'missing') ? 'missing captain last name' and resolved_at is null) then raise exception 'missing captain last name was not withheld and alerted'; end if;

  update pace_v2.captains set last_name=v_original_last_name where id=v_captain_id;
  perform public.v2_system_schedule_t24_journey_notifications(v_as_of+interval '60 minutes');
  if not exists(select 1 from pace_v2.notifications where booking_id=v_booking_id and template_code='journey_tomorrow') or exists(select 1 from pace_v2.operational_alerts where exception_key='t24_details_overdue:'||v_booking_id::text and resolved_at is null) then raise exception 'corrected captain details did not queue and resolve immediately'; end if;
  update pace_v2.pickup_points set directions_url=v_original_directions where id=v_pickup_id;
end $$;

rollback;
