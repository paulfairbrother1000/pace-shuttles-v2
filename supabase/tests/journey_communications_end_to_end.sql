begin;

-- One rollback-only lifecycle over an existing eligible seed allocation. The fixture
-- makes exactly two distinct party-leader bookings active/paid, fixes all scheduler
-- inputs, and cancels every other booking on that allocation for deterministic fan-out.
create temporary table journey_communications_e2e_fixture(
  allocation_id uuid not null,
  departure_id uuid not null,
  country_id uuid not null,
  pickup_id uuid not null,
  booking_a_id uuid not null,
  booking_b_id uuid not null,
  owner_a_id uuid not null,
  owner_b_id uuid not null,
  captain_user_id uuid not null,
  t24_as_of timestamptz not null default now(),
  completion_ts timestamptz,
  feedback_due timestamptz,
  conversation_a_id uuid,
  conversation_b_id uuid,
  broadcast_source_id uuid,
  feedback_id uuid
) on commit drop;
grant select,update on journey_communications_e2e_fixture to authenticated,service_role;

insert into journey_communications_e2e_fixture(
  allocation_id,departure_id,country_id,pickup_id,booking_a_id,booking_b_id,
  owner_a_id,owner_b_id,captain_user_id
)
select ca.id,d.id,country.id,r.pickup_id,
  candidates.booking_ids[1],candidates.booking_ids[2],
  candidates.owner_ids[1],candidates.owner_ids[2],captain.auth_user_id
from pace_v2.confirmed_allocations ca
join pace_v2.departures d on d.id=ca.departure_id and d.status not in('cancelled','completed')
join pace_v2.routes r on r.id=d.route_id
join pace_v2.countries country on country.id=r.country_id
join pace_v2.pickup_points pp on pp.id=r.pickup_id
join pace_v2.destinations destination on destination.id=r.destination_id
join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active and nullif(trim(v.name),'') is not null
join pace_v2.vehicle_types vt on vt.id=v.vehicle_type_id and vt.active and nullif(trim(vt.name),'') is not null
join lateral(
  select cap.id,cap.auth_user_id
  from pace_v2.captain_assignments a
  join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id
    and cap.auth_user_id is not null and nullif(trim(cap.first_name),'') is not null and nullif(trim(cap.last_name),'') is not null
  join pace_v2.captain_vehicle_types cvt on cvt.captain_id=cap.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
  where a.confirmed_allocation_id=ca.id and a.active
  order by cap.id limit 1
) captain on true
join lateral(
  select array_agg(x.booking_id order by x.booking_id) booking_ids,array_agg(x.owner_id order by x.booking_id) owner_ids
  from(
    select distinct on(b.id) b.id booking_id,pace_v2.booking_owner_user_id(b.id) owner_id
    from pace_v2.bookings b
    join pace_v2.orders o on o.id=b.order_id
    join pace_v2.booking_allocations ba on ba.booking_id=b.id and ba.vehicle_consideration_id=ca.consideration_id
    join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id)
      and pace_v2.is_valid_customer_notification_email(u.email)
    where pace_v2.is_active_paid_journey_booking(b.id,null)
      and nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),'') is not null
      and pace_v2.booking_owner_user_id(b.id)<>captain.auth_user_id
    order by b.id limit 2
  ) x
) candidates on cardinality(candidates.booking_ids)=2 and candidates.owner_ids[1]<>candidates.owner_ids[2]
where ca.status='confirmed'
  and (select count(*) from pace_v2.captain_assignments a2 where a2.confirmed_allocation_id=ca.id and a2.active)=1
order by ca.id limit 1;

do $$ begin
  if not exists(select 1 from journey_communications_e2e_fixture) then
    raise exception 'fixture requires one confirmed eligible-captain allocation with two distinct valid-email paid party leaders';
  end if;
end $$;

update pace_v2.bookings b set status='booked'
from journey_communications_e2e_fixture f where b.id in(f.booking_a_id,f.booking_b_id);
update pace_v2.orders o set payment_status='paid'
from pace_v2.bookings b,journey_communications_e2e_fixture f
where o.id=b.order_id and b.id in(f.booking_a_id,f.booking_b_id);
update pace_v2.bookings b set status='cancelled'
from journey_communications_e2e_fixture f
join pace_v2.confirmed_allocations ca on ca.id=f.allocation_id
join pace_v2.booking_allocations ba on ba.vehicle_consideration_id=ca.consideration_id
where b.id=ba.booking_id and b.id not in(f.booking_a_id,f.booking_b_id);
update pace_v2.bookings b set customer_name=case when b.id=f.booking_a_id then 'Task Eight Customer A' else 'Task Eight Customer B' end
from journey_communications_e2e_fixture f where b.id in(f.booking_a_id,f.booking_b_id);
update pace_v2.pickup_points pp set directions_url='https://maps.app.goo.gl/task8release'
from journey_communications_e2e_fixture f where pp.id=f.pickup_id;
update pace_v2.countries c set timezone='America/Antigua'
from journey_communications_e2e_fixture f where c.id=f.country_id;
update pace_v2.departures d
set scheduled_departure_ts=f.t24_as_of+interval '24 hours',
    scheduled_arrival_ts=f.t24_as_of+interval '26 hours',
    actual_arrival_ts=null
from journey_communications_e2e_fixture f where d.id=f.departure_id;

-- Clear only the selected bookings' generated outputs so the unique/idempotency
-- assertions are repeatable against a seeded non-production database.
delete from pace_v2.platform_quality_history where booking_id in(select booking_a_id from journey_communications_e2e_fixture union all select booking_b_id from journey_communications_e2e_fixture);
delete from pace_v2.captain_quality_history where booking_id in(select booking_a_id from journey_communications_e2e_fixture union all select booking_b_id from journey_communications_e2e_fixture);
delete from pace_v2.pickup_quality_history where booking_id in(select booking_a_id from journey_communications_e2e_fixture union all select booking_b_id from journey_communications_e2e_fixture);
delete from pace_v2.destination_quality_history where booking_id in(select booking_a_id from journey_communications_e2e_fixture union all select booking_b_id from journey_communications_e2e_fixture);
delete from pace_v2.quality_evidence where booking_id in(select booking_a_id from journey_communications_e2e_fixture union all select booking_b_id from journey_communications_e2e_fixture);
delete from pace_v2.operational_alerts where booking_id in(select booking_a_id from journey_communications_e2e_fixture union all select booking_b_id from journey_communications_e2e_fixture) and exception_type in('t24_details_overdue','feedback_timezone_invalid','journey_feedback_attribution_review');
delete from pace_v2.customer_feedback where booking_id in(select booking_a_id from journey_communications_e2e_fixture union all select booking_b_id from journey_communications_e2e_fixture);
delete from pace_v2.notifications where booking_id in(select booking_a_id from journey_communications_e2e_fixture union all select booking_b_id from journey_communications_e2e_fixture) and template_code in('journey_tomorrow','journey_broadcast','post_journey_feedback');

-- T-24: no early work, exactly two rows at the inclusive boundary, and no duplicate
-- rows when the service scheduler retries the same as-of timestamp.
set local role service_role;
select public.v2_system_schedule_t24_journey_notifications((select t24_as_of-interval '1 microsecond' from journey_communications_e2e_fixture));
reset role;
do $$ begin
  if exists(
    select 1 from pace_v2.notifications n join journey_communications_e2e_fixture f on n.booking_id in(f.booking_a_id,f.booking_b_id)
    where n.template_code='journey_tomorrow'
  ) then raise exception 'T-24 reminder queued before the exact boundary'; end if;
end $$;
set local role service_role;
select public.v2_system_schedule_t24_journey_notifications((select t24_as_of from journey_communications_e2e_fixture));
select public.v2_system_schedule_t24_journey_notifications((select t24_as_of from journey_communications_e2e_fixture));
reset role;
do $$ declare v_count integer; begin
  select count(*) into v_count
  from pace_v2.notifications n join journey_communications_e2e_fixture f on n.booking_id in(f.booking_a_id,f.booking_b_id)
  where n.template_code='journey_tomorrow';
  if v_count<>2 then raise exception 'T-24 expected exactly two idempotent reminders, got %',v_count; end if;
  if exists(
    select n.booking_id from pace_v2.notifications n join journey_communications_e2e_fixture f on n.booking_id in(f.booking_a_id,f.booking_b_id)
    where n.template_code='journey_tomorrow' group by n.booking_id having count(*)<>1
  ) then raise exception 'T-24 reminder was not unique per booking'; end if;
end $$;

-- The two customers open separate threads, the assigned captain replies only to A,
-- and one captain broadcast fans out as two private copies plus two queued emails.
select set_config('request.jwt.claim.sub',(select owner_a_id::text from journey_communications_e2e_fixture),true);
set local role authenticated;
update journey_communications_e2e_fixture
set conversation_a_id=public.v2_customer_open_captain_conversation(booking_a_id,'Customer A needs pickup confirmation');
reset role;
select set_config('request.jwt.claim.sub',(select owner_b_id::text from journey_communications_e2e_fixture),true);
set local role authenticated;
update journey_communications_e2e_fixture
set conversation_b_id=public.v2_customer_open_captain_conversation(booking_b_id,'Customer B needs pickup confirmation');
reset role;
select set_config('request.jwt.claim.sub',(select captain_user_id::text from journey_communications_e2e_fixture),true);
set local role authenticated;
select public.v2_captain_reply_to_party((select conversation_a_id from journey_communications_e2e_fixture),'Captain private reply to A','operational');
update journey_communications_e2e_fixture
set broadcast_source_id=public.v2_captain_broadcast_to_parties(allocation_id,'Weather remains suitable; please arrive 15 minutes early.','weather',gen_random_uuid());
reset role;

do $$ declare v_deliveries integer; v_copies integer; v_notifications integer; begin
  select count(*) into v_deliveries
  from pace_v2.journey_broadcast_deliveries d join journey_communications_e2e_fixture f on d.broadcast_message_id=f.broadcast_source_id;
  select count(*) into v_copies
  from pace_v2.journey_conversation_messages m join journey_communications_e2e_fixture f on m.broadcast_source_id=f.broadcast_source_id;
  select count(*) into v_notifications
  from pace_v2.notifications n
  join pace_v2.journey_broadcast_deliveries d on n.metadata->>'journey_broadcast_delivery_id'=d.id::text
  join journey_communications_e2e_fixture f on d.broadcast_message_id=f.broadcast_source_id;
  if v_deliveries<>2 or v_copies<>2 or v_notifications<>2 then
    raise exception 'broadcast expected two private deliveries/copies/emails, got %/%/%',v_deliveries,v_copies,v_notifications;
  end if;
  if exists(
    select 1 from pace_v2.journey_broadcast_deliveries d join journey_communications_e2e_fixture f on d.broadcast_message_id=f.broadcast_source_id
    where d.booking_id not in(f.booking_a_id,f.booking_b_id)
  ) then raise exception 'broadcast escaped the two-party fixture'; end if;
end $$;

select set_config('request.jwt.claim.sub',(select owner_a_id::text from journey_communications_e2e_fixture),true);
set local role authenticated;
do $$ declare v_visible integer; begin
  select count(*) into v_visible
  from public.v2_customer_my_journey_messages m join journey_communications_e2e_fixture f on m.id=f.broadcast_source_id or m.broadcast_source_id=f.broadcast_source_id;
  if v_visible<>1 then raise exception 'customer A did not receive exactly one private broadcast copy: %',v_visible; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub',(select owner_b_id::text from journey_communications_e2e_fixture),true);
set local role authenticated;
do $$ declare v_visible integer; begin
  select count(*) into v_visible
  from public.v2_customer_my_journey_messages m join journey_communications_e2e_fixture f on m.id=f.broadcast_source_id or m.broadcast_source_id=f.broadcast_source_id;
  if v_visible<>1 then raise exception 'customer B did not receive exactly one private broadcast copy: %',v_visible; end if;
end $$;
reset role;

-- Record actual completion. The authority stays open until one microsecond before
-- completion +4h and is closed at the exact +4h boundary.
update journey_communications_e2e_fixture set completion_ts=now()-interval '1 second';
update pace_v2.departures d set actual_arrival_ts=f.completion_ts
from journey_communications_e2e_fixture f where d.id=f.departure_id;
do $$ begin
  if not pace_v2.is_journey_message_window_open(
    p_confirmed_allocation_id=>(select allocation_id from journey_communications_e2e_fixture),
    p_as_of=>(select completion_ts+interval '4 hours'-interval '1 microsecond' from journey_communications_e2e_fixture)
  ) then raise exception 'messaging closed before actual completion +4h'; end if;
  if pace_v2.is_journey_message_window_open(
    p_confirmed_allocation_id=>(select allocation_id from journey_communications_e2e_fixture),
    p_as_of=>(select completion_ts+interval '4 hours' from journey_communications_e2e_fixture)
  ) then raise exception 'messaging remained open at actual completion +4h'; end if;
end $$;

-- Feedback becomes due at 10:00 on the next America/Antigua local calendar day.
update journey_communications_e2e_fixture
set feedback_due=pace_v2.feedback_due_at(completion_ts,'America/Antigua');
do $$ begin
  if ((select feedback_due from journey_communications_e2e_fixture) at time zone 'America/Antigua')::time is distinct from time '10:00'
    or ((select feedback_due from journey_communications_e2e_fixture) at time zone 'America/Antigua')::date
      is distinct from (((select completion_ts from journey_communications_e2e_fixture) at time zone 'America/Antigua')::date+1) then
    raise exception 'feedback due time is not next local day at 10:00';
  end if;
end $$;
set local role service_role;
select public.v2_system_schedule_feedback_requests((select feedback_due-interval '1 microsecond' from journey_communications_e2e_fixture),500);
reset role;
do $$ begin
  if exists(
    select 1 from pace_v2.notifications n join journey_communications_e2e_fixture f on n.booking_id in(f.booking_a_id,f.booking_b_id)
    where n.template_code='post_journey_feedback'
  ) then raise exception 'feedback queued before next-day 10:00 local'; end if;
end $$;
set local role service_role;
select public.v2_system_schedule_feedback_requests((select feedback_due from journey_communications_e2e_fixture),500);
select public.v2_system_schedule_feedback_requests((select feedback_due from journey_communications_e2e_fixture),500);
reset role;
do $$ declare v_count integer; begin
  select count(*) into v_count
  from pace_v2.notifications n join journey_communications_e2e_fixture f on n.booking_id in(f.booking_a_id,f.booking_b_id)
  where n.template_code='post_journey_feedback' and n.scheduled_at=f.feedback_due;
  if v_count<>2 then raise exception 'feedback expected exactly two idempotent next-day requests, got %',v_count; end if;
end $$;

-- Customer A submits all ratings. The database derives immutable attribution and
-- proves the configurable operator/captain 60/40 split without leaking platform or
-- location measures into operator quality.
select set_config('request.jwt.claim.sub',(select owner_a_id::text from journey_communications_e2e_fixture),true);
set local role authenticated;
update journey_communications_e2e_fixture
set feedback_id=public.v2_customer_submit_feedback(
  booking_a_id,5,10,5,1,4,2,'The captain communication was clear','The destination arrival could improve',false
);
reset role;
do $$ begin
  if not exists(select 1 from pace_v2.quality_configuration where config_key='journey_feedback' and operator_rating_weight=0.60 and captain_rating_weight=0.40) then
    raise exception 'journey feedback 60/40 quality configuration missing';
  end if;
  if not exists(
    select 1 from pace_v2.quality_evidence qe join journey_communications_e2e_fixture f on qe.feedback_id=f.feedback_id
    where qe.dimension='operator_journey' and qe.rating=5 and operator_score_effect is not distinct from 0.20
  ) then raise exception 'operator/captain 60/40 weighted evidence was not 0.20'; end if;
  if exists(
    select 1 from pace_v2.quality_evidence qe join journey_communications_e2e_fixture f on qe.feedback_id=f.feedback_id
    where qe.dimension in('pace_shuttles_nps','booking_experience','pickup','destination') and qe.operator_score_effect<>0
  ) then raise exception 'platform or location feedback leaked into operator quality'; end if;
  if not exists(
    select 1 from pace_v2.captain_quality_history h join journey_communications_e2e_fixture f on h.feedback_id=f.feedback_id
    where h.rating=1 and h.rating_effect=-1
  ) then raise exception 'captain quality was not retained separately'; end if;
  if not exists(
    select 1 from pace_v2.pickup_quality_history h join journey_communications_e2e_fixture f on h.feedback_id=f.feedback_id where h.rating=4
  ) or not exists(
    select 1 from pace_v2.destination_quality_history h join journey_communications_e2e_fixture f on h.feedback_id=f.feedback_id where h.rating=2
  ) then raise exception 'pickup/destination quality was not retained separately'; end if;
  if (select count(*) from pace_v2.platform_quality_history h join journey_communications_e2e_fixture f on h.feedback_id=f.feedback_id)<>2 then
    raise exception 'booking-experience and NPS histories were not retained separately';
  end if;
end $$;

rollback;
