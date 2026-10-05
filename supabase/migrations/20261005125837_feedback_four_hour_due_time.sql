-- Use final recorded completion and a four-elapsed-hour invitation delay.
CREATE OR REPLACE FUNCTION pace_v2.feedback_due_at(p_actual_arrival_ts timestamp with time zone, p_timezone text)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE STRICT
 SET search_path TO 'pace_v2', 'public'
AS $function$
begin
  -- Retain timezone validation, but use elapsed time rather than a wall-clock date.
  perform p_actual_arrival_ts at time zone p_timezone;
  return p_actual_arrival_ts + interval '4 hours';
end;
$function$
;
CREATE OR REPLACE FUNCTION public.v2_system_schedule_feedback_requests(p_as_of timestamp with time zone, p_limit integer DEFAULT 100)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pace_v2', 'auth'
AS $function$
declare v_row record; v_due_at timestamptz; v_queued integer:=0; v_feedback_url text;
begin
  if p_as_of is null then raise exception 'as-of timestamp required'; end if;
  update pace_v2.operational_alerts oa
  set resolved_at=now(),resolution_note='Country timezone corrected; feedback request will be queued when due'
  from pace_v2.confirmed_allocations ca
  join pace_v2.departures d on d.id=ca.departure_id
  join pace_v2.routes r on r.id=d.route_id
  join pace_v2.countries c on c.id=r.country_id
  join pg_timezone_names tz on tz.name=c.timezone
  where oa.exception_type='feedback_timezone_invalid' and oa.resolved_at is null and oa.confirmed_allocation_id=ca.id;
  insert into pace_v2.operational_alerts(exception_key,exception_type,severity,confirmed_allocation_id,booking_id,departure_id,details)
  select distinct on (b.id)
    'feedback_timezone_invalid:'||b.id::text,'feedback_timezone_invalid','high',ca.id,b.id,d.id,
    jsonb_build_object('country_name',c.name,'timezone',c.timezone,'as_of',p_as_of)
  from pace_v2.bookings b
  join pace_v2.booking_allocations ba on ba.booking_id=b.id
  join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status='completed'
  join pace_v2.departures d on d.id=ca.departure_id
  join pace_v2.routes r on r.id=d.route_id
  join pace_v2.countries c on c.id=r.country_id
  left join pg_timezone_names tz on tz.name=c.timezone
  join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id
  join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id)
  where d.status='completed' and tz.name is null and coalesce(d.completed_at,d.actual_arrival_ts) is not null and coalesce(d.completed_at,d.actual_arrival_ts)<=p_as_of
    and pace_v2.is_active_paid_journey_booking(b.id,null)
    and not exists(select 1 from pace_v2.customer_feedback cf where cf.booking_id=b.id)
    and pace_v2.is_valid_customer_notification_email(u.email)
    and nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),'') is not null
    and (select count(*) from pace_v2.captain_assignments a2 where a2.confirmed_allocation_id=ca.id and a2.active)=1
    and not exists(select 1 from pace_v2.notifications n where n.booking_id=b.id and n.template_code='post_journey_feedback')
  order by b.id,ca.id,a.id
  on conflict (exception_key) where resolved_at is null do update
    set severity='high',confirmed_allocation_id=excluded.confirmed_allocation_id,departure_id=excluded.departure_id,details=excluded.details,detected_at=excluded.detected_at;
  for v_row in
    select distinct on (b.id) b.id booking_id,ca.id confirmed_allocation_id,d.id departure_id,coalesce(d.completed_at,d.actual_arrival_ts) as actual_arrival_ts,c.name country_name,c.timezone,
      pp.name pickup_name,dst.name destination_name,nullif(trim(u.email),'') to_email,
      split_part(nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),''),' ',1) first_name
    from pace_v2.bookings b
    join pace_v2.booking_allocations ba on ba.booking_id=b.id
    join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status='completed'
    join pace_v2.departures d on d.id=ca.departure_id
    join pace_v2.routes r on r.id=d.route_id
    join pace_v2.countries c on c.id=r.country_id
    join pg_timezone_names tz on tz.name=c.timezone
    join pace_v2.pickup_points pp on pp.id=r.pickup_id
    join pace_v2.destinations dst on dst.id=r.destination_id
    join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
    join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id
    join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id)
    where d.status='completed' and coalesce(d.completed_at,d.actual_arrival_ts) is not null and coalesce(d.completed_at,d.actual_arrival_ts)<=p_as_of
      and case when tz.name is not null then pace_v2.feedback_due_at(coalesce(d.completed_at,d.actual_arrival_ts),c.timezone)<=p_as_of else false end
      and pace_v2.is_active_paid_journey_booking(b.id,null)
      and not exists(select 1 from pace_v2.customer_feedback cf where cf.booking_id=b.id)
      and not exists(select 1 from pace_v2.notifications n where n.booking_id=b.id and n.template_code='post_journey_feedback')
      and pace_v2.is_valid_customer_notification_email(u.email)
      and nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),'') is not null
      and (select count(*) from pace_v2.captain_assignments a2 where a2.confirmed_allocation_id=ca.id and a2.active)=1
    order by b.id,ca.id,a.id
    limit least(greatest(coalesce(p_limit,0),0),500)
  loop
    v_due_at:=pace_v2.feedback_due_at(v_row.actual_arrival_ts,v_row.timezone);
    v_feedback_url:='https://www.paceshuttles.com/customer?booking='||v_row.booking_id::text||'&feedback=1';
    insert into pace_v2.notifications(booking_id,departure_id,to_email,template_code,subject,body,status,scheduled_at,metadata)
    values(v_row.booking_id,v_row.departure_id,v_row.to_email,'post_journey_feedback',
      'Thank you for travelling with Pace Shuttles – one more thing…',
      'Hi '||v_row.first_name||E',\n\nThank you for travelling with Pace Shuttles. We hope you had a wonderful journey in '||v_row.country_name||' from '||v_row.pickup_name||' to '||v_row.destination_name||E'.\n\nWould you mind telling us what went well and what we could improve? It should take no more than two minutes.\n\nShare your feedback\n'||v_feedback_url||E'\n\nRegards,\nThe Pace Shuttles Team',
      'queued',v_due_at,jsonb_build_object('feedback_url',v_feedback_url,'feedback_due_at',v_due_at,'country_name',v_row.country_name,'pickup_name',v_row.pickup_name,'destination_name',v_row.destination_name))
    on conflict (booking_id,template_code) where template_code='post_journey_feedback' do nothing;
    if found then v_queued:=v_queued+1; end if;
  end loop;
  return v_queued;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.v2_site_admin_scheduled_event_calendar(p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS TABLE(event_key text, departure_id uuid, booking_id uuid, route_name text, event_type text, due_at timestamp with time zone, journey_timezone text, execution_source text, executed_at timestamp with time zone, status text, failure_reason text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pace_v2', 'public'
AS $function$
declare v_enabled boolean;
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 if p_from is null or p_to is null or p_to<=p_from or p_to-p_from>interval '180 days' then raise exception 'calendar range must be between 1 second and 180 days'; end if;
 select sc.enabled into v_enabled from pace_v2.scheduler_control sc where sc.control_key='journey_operations';
 return query
 with candidate as (
  select b.id as booking_id,d.id as departure_id,concat_ws(' to ',pp.name,dst.name) as route_name,c.timezone as journey_timezone,
   't24'::text as event_type,d.scheduled_departure_ts - interval '24 hours' as due_at
  from pace_v2.bookings b join pace_v2.orders o on o.id=b.order_id
  join pace_v2.departures d on d.id=nullif(to_jsonb(b)->>'departure_id','')::uuid
  join pace_v2.routes r on r.id=d.route_id join pace_v2.countries c on c.id=r.country_id
  join pace_v2.pickup_points pp on pp.id=r.pickup_id join pace_v2.destinations dst on dst.id=r.destination_id
  where lower(coalesce(to_jsonb(o)->>'payment_status',to_jsonb(o)->>'status','')) in('paid','succeeded','complete','completed')
  union all
  select b.id,d.id,concat_ws(' to ',pp.name,dst.name),c.timezone,'feedback',
   coalesce(nullif(to_jsonb(d)->>'completed_at','')::timestamptz,nullif(to_jsonb(d)->>'actual_arrival_ts','')::timestamptz)+interval '4 hours'
  from pace_v2.bookings b join pace_v2.orders o on o.id=b.order_id
  join pace_v2.departures d on d.id=nullif(to_jsonb(b)->>'departure_id','')::uuid
  join pace_v2.routes r on r.id=d.route_id join pace_v2.countries c on c.id=r.country_id
  join pace_v2.pickup_points pp on pp.id=r.pickup_id join pace_v2.destinations dst on dst.id=r.destination_id
  where d.status='completed' and lower(coalesce(to_jsonb(o)->>'payment_status',to_jsonb(o)->>'status','')) in('paid','succeeded','complete','completed')
 ), joined as (
  select x.*,n.status as notification_status,n.scheduled_at,n.created_at,n.metadata,
   nullif(coalesce(to_jsonb(n)->>'sent_at',to_jsonb(n)->>'failed_at',to_jsonb(n)->>'updated_at'), '')::timestamptz as notification_executed_at,
   coalesce(to_jsonb(n)->>'failure_message',to_jsonb(n)->>'last_error') as notification_failure
  from candidate x left join pace_v2.notifications n on n.booking_id=x.booking_id and n.template_code=case when x.event_type='t24' then 'journey_tomorrow' else 'post_journey_feedback' end
  where x.due_at>=p_from and x.due_at<p_to
 )
 select j.event_type||':'||j.booking_id::text,j.departure_id,j.booking_id,j.route_name,j.event_type,j.due_at,j.journey_timezone,
  coalesce(j.metadata->>'execution_source','scheduled'),coalesce(j.notification_executed_at,case when j.notification_status in('sending','sent','failed') then j.created_at end),
  case when j.notification_status='sent' then 'sent' when j.notification_status='sending' then 'processing' when j.notification_status='failed' then 'failed'
   when not v_enabled and j.due_at<=now() then 'overdue' when not v_enabled then 'paused' when j.due_at<=now() then 'overdue' else 'pending' end,
  left(j.notification_failure,500)
 from joined j order by j.due_at,j.event_type,j.booking_id;
end $function$
;
