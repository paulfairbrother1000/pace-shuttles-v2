begin;

do $$
begin
  if pace_v2.feedback_due_at('2030-01-02 15:30:00+00','America/Antigua') is distinct from '2030-01-03 14:00:00+00'::timestamptz then
    raise exception 'Antigua next-local-calendar-day 10:00 scheduling is wrong';
  end if;
  if pace_v2.feedback_due_at('2030-03-10 04:30:00+00','America/New_York') is distinct from '2030-03-10 14:00:00+00'::timestamptz then
    raise exception 'DST spring transition did not preserve 10:00 local scheduling';
  end if;
  if pace_v2.feedback_due_at('2030-11-03 03:30:00+00','America/New_York') is distinct from '2030-11-03 15:00:00+00'::timestamptz then
    raise exception 'DST fall transition did not preserve 10:00 local scheduling';
  end if;
begin
  perform pace_v2.feedback_due_at(now(),'Not/A-Timezone');
  raise exception 'invalid timezone was accepted';
exception when invalid_parameter_value then null;
end;
end $$;

create temporary table feedback_timezone_starvation_fixture as
with eligible as (
  select b.id booking_id,ca.id confirmed_allocation_id,d.id departure_id,r.country_id,c.timezone,d.actual_arrival_ts
  from pace_v2.bookings b
  join pace_v2.booking_allocations ba on ba.booking_id=b.id
  join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status='confirmed'
  join pace_v2.departures d on d.id=ca.departure_id
  join pace_v2.routes r on r.id=d.route_id
  join pace_v2.countries c on c.id=r.country_id
  join pg_timezone_names tz on tz.name=c.timezone
  join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id
  join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id)
  where pace_v2.is_active_paid_journey_booking(b.id,null)
    and pace_v2.is_valid_customer_notification_email(u.email)
    and nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),'') is not null
    and (select count(*) from pace_v2.captain_assignments a2 where a2.confirmed_allocation_id=ca.id and a2.active)=1
)
select invalid.booking_id earlier_invalid_booking_id,invalid.confirmed_allocation_id earlier_invalid_allocation_id,
  invalid.departure_id earlier_invalid_departure_id,invalid.country_id earlier_invalid_country_id,
  invalid.timezone earlier_invalid_original_timezone,invalid.actual_arrival_ts earlier_invalid_original_arrival,
  valid.booking_id later_valid_booking_id,valid.confirmed_allocation_id later_valid_allocation_id,
  valid.departure_id later_valid_departure_id,valid.country_id later_valid_country_id,
  valid.timezone later_valid_original_timezone,valid.actual_arrival_ts later_valid_original_arrival
from eligible invalid
join eligible valid on invalid.booking_id<valid.booking_id and invalid.country_id<>valid.country_id
order by invalid.booking_id,valid.booking_id
limit 1;

do $$ begin if not exists(select 1 from feedback_timezone_starvation_fixture) then raise exception 'fixture: earlier invalid and later valid eligible bookings in distinct countries required'; end if; end $$;

delete from pace_v2.platform_quality_history where booking_id in(select earlier_invalid_booking_id from feedback_timezone_starvation_fixture union all select later_valid_booking_id from feedback_timezone_starvation_fixture);
delete from pace_v2.captain_quality_history where booking_id in(select earlier_invalid_booking_id from feedback_timezone_starvation_fixture union all select later_valid_booking_id from feedback_timezone_starvation_fixture);
delete from pace_v2.pickup_quality_history where booking_id in(select earlier_invalid_booking_id from feedback_timezone_starvation_fixture union all select later_valid_booking_id from feedback_timezone_starvation_fixture);
delete from pace_v2.destination_quality_history where booking_id in(select earlier_invalid_booking_id from feedback_timezone_starvation_fixture union all select later_valid_booking_id from feedback_timezone_starvation_fixture);
delete from pace_v2.quality_evidence where booking_id in(select earlier_invalid_booking_id from feedback_timezone_starvation_fixture union all select later_valid_booking_id from feedback_timezone_starvation_fixture);
delete from pace_v2.operational_alerts where booking_id in(select earlier_invalid_booking_id from feedback_timezone_starvation_fixture union all select later_valid_booking_id from feedback_timezone_starvation_fixture) and exception_type in('journey_feedback_attribution_review','feedback_timezone_invalid');
delete from pace_v2.customer_feedback where booking_id in(select earlier_invalid_booking_id from feedback_timezone_starvation_fixture union all select later_valid_booking_id from feedback_timezone_starvation_fixture);
delete from pace_v2.notifications where booking_id in(select earlier_invalid_booking_id from feedback_timezone_starvation_fixture union all select later_valid_booking_id from feedback_timezone_starvation_fixture) and template_code='post_journey_feedback';

insert into pace_v2.notifications(booking_id,departure_id,to_email,template_code,subject,body,status,scheduled_at,metadata)
select b.id,d.id,trim(u.email),'post_journey_feedback','Fixture scheduling blocker','Fixture scheduling blocker','queued','2030-01-03 14:00:00+00',jsonb_build_object('fixture','feedback_timezone_starvation')
from pace_v2.bookings b
join pace_v2.booking_allocations ba on ba.booking_id=b.id
join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status='confirmed'
join pace_v2.departures d on d.id=ca.departure_id
join pace_v2.routes r on r.id=d.route_id
join pace_v2.countries c on c.id=r.country_id
join pg_timezone_names tz on tz.name=c.timezone
join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id
join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id)
where pace_v2.is_active_paid_journey_booking(b.id,null)
  and pace_v2.is_valid_customer_notification_email(u.email)
  and nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),'') is not null
  and (select count(*) from pace_v2.captain_assignments a2 where a2.confirmed_allocation_id=ca.id and a2.active)=1
  and b.id not in(select earlier_invalid_booking_id from feedback_timezone_starvation_fixture union all select later_valid_booking_id from feedback_timezone_starvation_fixture)
on conflict (booking_id,template_code) where template_code='post_journey_feedback' do nothing;

update pace_v2.countries c set timezone='Invalid/Timezone' from feedback_timezone_starvation_fixture f where c.id=f.earlier_invalid_country_id;
update pace_v2.countries c set timezone='America/Antigua' from feedback_timezone_starvation_fixture f where c.id=f.later_valid_country_id;
update pace_v2.departures d set actual_arrival_ts='2030-01-02 15:30:00+00' from feedback_timezone_starvation_fixture f where d.id in(f.earlier_invalid_departure_id,f.later_valid_departure_id);

do $$
declare v_queued integer;
begin
  v_queued:=public.v2_system_schedule_feedback_requests('2030-01-03 14:00:00+00',1);
  if v_queued<>1 or not exists(select 1 from pace_v2.notifications n join feedback_timezone_starvation_fixture f on f.later_valid_booking_id=n.booking_id where n.template_code='post_journey_feedback') then raise exception 'valid due booking was starved by invalid timezone alert processing'; end if;
  if exists(select 1 from pace_v2.notifications n join feedback_timezone_starvation_fixture f on f.earlier_invalid_booking_id=n.booking_id where n.template_code='post_journey_feedback') then raise exception 'invalid timezone booking was queued during starvation test'; end if;
  if not exists(select 1 from pace_v2.operational_alerts oa join feedback_timezone_starvation_fixture f on f.earlier_invalid_booking_id=oa.booking_id where oa.exception_type='feedback_timezone_invalid' and oa.resolved_at is null) then raise exception 'independent invalid timezone alert processing did not run'; end if;
end $$;

update pace_v2.countries c set timezone=f.earlier_invalid_original_timezone from feedback_timezone_starvation_fixture f where c.id=f.earlier_invalid_country_id;
update pace_v2.countries c set timezone=f.later_valid_original_timezone from feedback_timezone_starvation_fixture f where c.id=f.later_valid_country_id;
update pace_v2.departures d set actual_arrival_ts=f.earlier_invalid_original_arrival from feedback_timezone_starvation_fixture f where d.id=f.earlier_invalid_departure_id;
update pace_v2.departures d set actual_arrival_ts=f.later_valid_original_arrival from feedback_timezone_starvation_fixture f where d.id=f.later_valid_departure_id;
delete from pace_v2.operational_alerts where booking_id=(select earlier_invalid_booking_id from feedback_timezone_starvation_fixture) and exception_type='feedback_timezone_invalid';
delete from pace_v2.notifications where template_code='post_journey_feedback' and (metadata->>'fixture'='feedback_timezone_starvation' or booking_id in(select earlier_invalid_booking_id from feedback_timezone_starvation_fixture union all select later_valid_booking_id from feedback_timezone_starvation_fixture));

create temporary table journey_feedback_fixture as
select b.id booking_id,pace_v2.booking_owner_user_id(b.id) owner_id,ca.id confirmed_allocation_id,
  ca.operator_id,ca.vehicle_id,d.id departure_id,r.country_id,r.pickup_id,r.destination_id,a.captain_id,
  c.timezone original_timezone,d.actual_arrival_ts original_actual_arrival
from pace_v2.bookings b
join pace_v2.booking_allocations ba on ba.booking_id=b.id
join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status='confirmed'
join pace_v2.departures d on d.id=ca.departure_id
join pace_v2.routes r on r.id=d.route_id
join pace_v2.countries c on c.id=r.country_id
join pg_timezone_names tz on tz.name=c.timezone
join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id
join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id)
where pace_v2.booking_owner_user_id(b.id) is not null
  and pace_v2.is_active_paid_journey_booking(b.id,null)
  and pace_v2.is_valid_customer_notification_email(u.email)
  and nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),'') is not null
  and (select count(*) from pace_v2.captain_assignments a2 where a2.confirmed_allocation_id=ca.id and a2.active)=1
order by b.id limit 1;
grant select on journey_feedback_fixture to authenticated;

do $$ begin if not exists(select 1 from journey_feedback_fixture) then raise exception 'fixture: eligible paid party-leader booking required'; end if; end $$;

delete from pace_v2.platform_quality_history where booking_id=(select booking_id from journey_feedback_fixture);
delete from pace_v2.captain_quality_history where booking_id=(select booking_id from journey_feedback_fixture);
delete from pace_v2.pickup_quality_history where booking_id=(select booking_id from journey_feedback_fixture);
delete from pace_v2.destination_quality_history where booking_id=(select booking_id from journey_feedback_fixture);
delete from pace_v2.quality_evidence where booking_id=(select booking_id from journey_feedback_fixture);
delete from pace_v2.operational_alerts where booking_id=(select booking_id from journey_feedback_fixture) and exception_type in('journey_feedback_attribution_review','feedback_timezone_invalid');
delete from pace_v2.customer_feedback where booking_id=(select booking_id from journey_feedback_fixture);
delete from pace_v2.notifications where booking_id=(select booking_id from journey_feedback_fixture) and template_code='post_journey_feedback';

do $$
declare v_feedback_id uuid; v_consent boolean; v_version integer;
begin
  insert into pace_v2.customer_feedback(booking_id,departure_id,confirmed_allocation_id,operator_id,vehicle_id,captain_id,pickup_id,destination_id,submitted_by,booking_experience_rating,pace_shuttles_nps_score,operator_rating,captain_rating,pickup_rating,destination_rating)
  select booking_id,departure_id,confirmed_allocation_id,operator_id,vehicle_id,captain_id,pickup_id,destination_id,owner_id,5,10,5,5,5,5 from journey_feedback_fixture returning id,testimonial_consent,feedback_schema_version into v_feedback_id,v_consent,v_version;
  if v_consent is distinct from false or v_version is distinct from 2 then raise exception 'new feedback defaults expected false consent/schema version 2, got %/%',v_consent,v_version; end if;
  delete from pace_v2.platform_quality_history where feedback_id=v_feedback_id;
  delete from pace_v2.captain_quality_history where feedback_id=v_feedback_id;
  delete from pace_v2.pickup_quality_history where feedback_id=v_feedback_id;
  delete from pace_v2.destination_quality_history where feedback_id=v_feedback_id;
  delete from pace_v2.quality_evidence where feedback_id=v_feedback_id;
  delete from pace_v2.customer_feedback where id=v_feedback_id;
end $$;

update pace_v2.countries c set timezone='America/Antigua' from journey_feedback_fixture f where c.id=f.country_id;
update pace_v2.departures d set actual_arrival_ts='2030-01-02 15:30:00+00' from journey_feedback_fixture f where d.id=f.departure_id;

do $$
declare v_count integer;
begin
  perform public.v2_system_schedule_feedback_requests('2030-01-02 15:29:59+00',100);
  perform public.v2_system_schedule_feedback_requests('2030-01-03 13:59:59+00',100);
  if exists(select 1 from pace_v2.notifications n join journey_feedback_fixture f on f.booking_id=n.booking_id where n.template_code='post_journey_feedback') then
    raise exception 'feedback was queued before actual completion or before 10:00 next local day';
  end if;
  perform public.v2_system_schedule_feedback_requests('2030-01-03 14:00:00+00',100);
  perform public.v2_system_schedule_feedback_requests('2030-01-03 14:00:00+00',100);
  select count(*) into v_count from pace_v2.notifications n join journey_feedback_fixture f on f.booking_id=n.booking_id where n.template_code='post_journey_feedback';
  if v_count<>1 then raise exception 'feedback scheduler expected exactly one notification, got %',v_count; end if;
  if not exists(select 1 from pace_v2.notifications n join journey_feedback_fixture f on f.booking_id=n.booking_id where n.template_code='post_journey_feedback' and n.scheduled_at='2030-01-03 14:00:00+00' and n.body like '%what went well and what we could improve%' and n.body like '%no more than two minutes%' and n.body like '%/customer?booking='||f.booking_id::text||'&feedback=1%') then
    raise exception 'feedback notification lacks approved copy, due time or booking deep link';
  end if;
end $$;

delete from pace_v2.notifications where booking_id=(select booking_id from journey_feedback_fixture) and template_code='post_journey_feedback';
update pace_v2.countries c set timezone='Invalid/Timezone' from journey_feedback_fixture f where c.id=f.country_id;
select public.v2_system_schedule_feedback_requests('2030-01-02 15:30:00+00',100);
do $$ begin
  if exists(select 1 from pace_v2.notifications n join journey_feedback_fixture f on f.booking_id=n.booking_id where n.template_code='post_journey_feedback') then raise exception 'invalid timezone queued feedback email'; end if;
  if not exists(select 1 from pace_v2.operational_alerts oa join journey_feedback_fixture f on f.booking_id=oa.booking_id where oa.exception_type='feedback_timezone_invalid' and oa.resolved_at is null) then raise exception 'invalid timezone did not create active feedback alert'; end if;
end $$;
update pace_v2.countries c set timezone='America/Antigua' from journey_feedback_fixture f where c.id=f.country_id;
select public.v2_system_schedule_feedback_requests('2030-01-02 15:30:00+00',100);
do $$ begin
  if exists(select 1 from pace_v2.notifications n join journey_feedback_fixture f on f.booking_id=n.booking_id where n.template_code='post_journey_feedback') then raise exception 'corrected timezone queued feedback before due time'; end if;
  if exists(select 1 from pace_v2.operational_alerts oa join journey_feedback_fixture f on f.booking_id=oa.booking_id where oa.exception_type='feedback_timezone_invalid' and oa.resolved_at is null) then raise exception 'corrected timezone alert remained active'; end if;
end $$;
select public.v2_system_schedule_feedback_requests('2030-01-03 14:00:00+00',100);
do $$ begin
  if not exists(select 1 from pace_v2.notifications n join journey_feedback_fixture f on f.booking_id=n.booking_id where n.template_code='post_journey_feedback') then raise exception 'corrected timezone did not queue feedback when due'; end if;
end $$;

update pace_v2.departures d set actual_arrival_ts=now()-interval '1 hour' from journey_feedback_fixture f where d.id=f.departure_id;
select set_config('request.jwt.claim.sub',(select owner_id::text from journey_feedback_fixture),true);
set local role authenticated;
select public.v2_customer_submit_feedback((select booking_id from journey_feedback_fixture),5,2,5,5,5,5,'Everything went well','',false);
reset role;

do $$
declare v_feedback_id uuid; v_effect numeric; v_column text;
begin
  select cf.id into v_feedback_id from pace_v2.customer_feedback cf join journey_feedback_fixture f on f.booking_id=cf.booking_id;
  if v_feedback_id is null then raise exception 'feedback response was not recorded'; end if;
  if not exists(select 1 from pace_v2.customer_feedback cf join journey_feedback_fixture f on f.booking_id=cf.booking_id where cf.operator_id=f.operator_id and cf.vehicle_id=f.vehicle_id and cf.captain_id=f.captain_id and cf.pickup_id=f.pickup_id and cf.destination_id=f.destination_id and not cf.testimonial_consent) then
    raise exception 'database did not derive journey attribution targets or false consent';
  end if;
  select qe.operator_score_effect into v_effect from pace_v2.quality_evidence qe where qe.feedback_id=v_feedback_id and qe.dimension='operator_journey';
  if v_effect is distinct from 1.00 then raise exception 'operator/captain weighted normalized effect expected 1.00, got %',v_effect; end if;
  if exists(select 1 from pace_v2.quality_evidence where feedback_id=v_feedback_id and dimension in('pace_shuttles_nps','booking_experience','pickup','destination') and operator_score_effect<>0) then
    raise exception 'platform or location feedback leaked into operator quality';
  end if;
  if not exists(select 1 from pace_v2.captain_quality_history where feedback_id=v_feedback_id and rating=5 and rating_effect=1)
    or not exists(select 1 from pace_v2.pickup_quality_history where feedback_id=v_feedback_id and rating=5)
    or not exists(select 1 from pace_v2.destination_quality_history where feedback_id=v_feedback_id and rating=5) then
    raise exception 'captain or location history was not kept separate';
  end if;
  if not exists(select 1 from pace_v2.operational_alerts oa where oa.booking_id=(select booking_id from journey_feedback_fixture) and oa.exception_type='journey_feedback_attribution_review' and oa.details->'low_dimensions' ? 'pace_shuttles_nps') then
    raise exception 'NPS-only low rating did not create attribution-review alert evidence';
  end if;
  if exists(select 1 from pace_v2.operational_alerts oa where oa.booking_id=(select booking_id from journey_feedback_fixture) and oa.exception_type='journey_feedback_attribution_review' and jsonb_array_length(oa.details->'low_dimensions')<>1) then raise exception 'NPS-only low rating created unrelated low dimensions'; end if;
  foreach v_column in array array['booking_experience_rating','operator_rating','captain_rating','pickup_rating','destination_rating'] loop
    begin execute format('update pace_v2.customer_feedback set %I=0 where id=$1',v_column) using v_feedback_id; raise exception '% rating 0 bypassed check',v_column; exception when check_violation then null; end;
    begin execute format('update pace_v2.customer_feedback set %I=6 where id=$1',v_column) using v_feedback_id; raise exception '% rating 6 bypassed check',v_column; exception when check_violation then null; end;
    begin execute format('update pace_v2.customer_feedback set %I=null where id=$1',v_column) using v_feedback_id; raise exception '% null bypassed required check',v_column; exception when check_violation then null; end;
  end loop;
  begin update pace_v2.customer_feedback set pace_shuttles_nps_score=-1 where id=v_feedback_id; raise exception 'NPS -1 bypassed check'; exception when check_violation then null; end;
  begin update pace_v2.customer_feedback set pace_shuttles_nps_score=11 where id=v_feedback_id; raise exception 'NPS 11 bypassed check'; exception when check_violation then null; end;
  begin update pace_v2.customer_feedback set pace_shuttles_nps_score=null where id=v_feedback_id; raise exception 'NPS null bypassed required check'; exception when check_violation then null; end;
end $$;

set local role authenticated;
do $$ begin
  perform public.v2_customer_submit_feedback((select booking_id from journey_feedback_fixture),5,10,5,5,5,5,'Again','Again',true);
  raise exception 'duplicate feedback was accepted';
exception when unique_violation then null;
end $$;
reset role;

rollback;
