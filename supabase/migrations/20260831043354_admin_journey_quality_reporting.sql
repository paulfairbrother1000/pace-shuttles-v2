-- Additive Site Admin journey communications projections and authoritative quality reporting.

create or replace view public.v2_admin_operational_alerts
with (security_barrier=true) as
select oa.id,oa.exception_key,oa.exception_type,oa.severity,oa.confirmed_allocation_id,oa.booking_id,oa.departure_id,
       concat_ws(' to ',pp.name,dst.name) route_name,oa.details,oa.detected_at,oa.resolved_at,oa.resolution_note,oa.created_at
from pace_v2.operational_alerts oa
left join pace_v2.departures d on d.id=oa.departure_id
left join pace_v2.routes r on r.id=d.route_id
left join pace_v2.pickup_points pp on pp.id=r.pickup_id
left join pace_v2.destinations dst on dst.id=r.destination_id
where pace_v2.is_site_admin();

create or replace view public.v2_admin_journey_conversations
with (security_barrier=true) as
select jc.id conversation_id,jc.booking_id,jc.confirmed_allocation_id,jc.status,jc.opened_at,jc.closed_at,jc.created_at,
       concat_ws(' to ',pp.name,dst.name) route_name,
       nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),'') customer_name,
       count(m.id) filter(where m.sender_type in('customer','captain','captain_broadcast'))::bigint unread_count
from pace_v2.journey_conversations jc
join pace_v2.bookings b on b.id=jc.booking_id
join pace_v2.confirmed_allocations ca on ca.id=jc.confirmed_allocation_id
join pace_v2.departures d on d.id=ca.departure_id
join pace_v2.routes r on r.id=d.route_id
join pace_v2.pickup_points pp on pp.id=r.pickup_id
join pace_v2.destinations dst on dst.id=r.destination_id
left join pace_v2.journey_conversation_messages m on m.conversation_id=jc.id
where pace_v2.is_site_admin()
group by jc.id,jc.booking_id,jc.confirmed_allocation_id,jc.status,jc.opened_at,jc.closed_at,jc.created_at,pp.name,dst.name,b.id;

create or replace view public.v2_admin_journey_messages
with (security_barrier=true) as
select m.id,m.conversation_id,m.sender_type,m.category,m.message_text,m.broadcast_source_id,m.created_at
from pace_v2.journey_conversation_messages m where pace_v2.is_site_admin();

create or replace view public.v2_admin_journey_broadcast_deliveries
with (security_barrier=true) as
select bd.id,bd.broadcast_message_id,bd.booking_id,bd.conversation_id,bd.delivered_at,bd.in_app_read_at,bd.email_status,
       bd.email_provider_id,bd.email_failed_at,bd.email_failure_reason,bd.created_at,concat_ws(' to ',pp.name,dst.name) route_name
from pace_v2.journey_broadcast_deliveries bd
join pace_v2.journey_conversations jc on jc.id=bd.conversation_id
join pace_v2.confirmed_allocations ca on ca.id=jc.confirmed_allocation_id
join pace_v2.departures d on d.id=ca.departure_id
join pace_v2.routes r on r.id=d.route_id
join pace_v2.pickup_points pp on pp.id=r.pickup_id
join pace_v2.destinations dst on dst.id=r.destination_id
where pace_v2.is_site_admin();

revoke all on public.v2_admin_operational_alerts,public.v2_admin_journey_conversations,public.v2_admin_journey_messages,public.v2_admin_journey_broadcast_deliveries from public,anon,authenticated;
grant select on public.v2_admin_operational_alerts,public.v2_admin_journey_conversations,public.v2_admin_journey_messages,public.v2_admin_journey_broadcast_deliveries to authenticated;

create or replace view pace_v2.site_admin_operator_quality_source as
select o.id,o.name,(to_jsonb(o)->>'quality_score')::numeric quality_score from pace_v2.operators o;
revoke all on pace_v2.site_admin_operator_quality_source from public,anon,authenticated;

create or replace function public.v2_site_admin_quality_dashboard()
returns jsonb language plpgsql stable security definer set search_path=public,pace_v2,auth as $dashboard$
declare v_platform jsonb; v_operators jsonb; v_captains jsonb; v_pickups jsonb; v_destinations jsonb;
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 select jsonb_build_object(
  'nps',case when count(cf.pace_shuttles_nps_score)>0 then round(100.0*(count(*) filter(where cf.pace_shuttles_nps_score>=9)-count(*) filter(where cf.pace_shuttles_nps_score<=6))/count(cf.pace_shuttles_nps_score)) else null end,
  'promoters',count(*) filter(where cf.pace_shuttles_nps_score>=9),'passives',count(*) filter(where cf.pace_shuttles_nps_score between 7 and 8),
  'detractors',count(*) filter(where cf.pace_shuttles_nps_score<=6),'booking_experience_average',avg(cf.booking_experience_rating) filter (where cf.booking_experience_rating is not null),
  'response_count',count(cf.pace_shuttles_nps_score),
  'trend',(avg(cf.booking_experience_rating) filter(where cf.booking_experience_rating is not null and cf.created_at>=now()-interval '30 days'))-(avg(cf.booking_experience_rating) filter(where cf.booking_experience_rating is not null and cf.created_at>=now()-interval '60 days' and cf.created_at<now()-interval '30 days'))
 ) into v_platform from pace_v2.customer_feedback cf;

 select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'name',q.name,'quality_score',q.quality_score,'response_count',q.response_count,
  'operator_average',q.operator_average,'captain_average',q.captain_average,'trend',q.trend,'attribution_states',q.attribution_states) order by q.name),'[]'::jsonb)
 into v_operators from(
  select oq.id,oq.name,oq.quality_score,count(cf.operator_rating) response_count,
   avg(cf.operator_rating) filter (where cf.operator_rating is not null) operator_average,
   avg(cf.captain_rating) filter (where cf.captain_rating is not null) captain_average,
   (avg(cf.operator_rating) filter(where cf.operator_rating is not null and cf.created_at>=now()-interval '30 days'))-(avg(cf.operator_rating) filter(where cf.operator_rating is not null and cf.created_at>=now()-interval '60 days' and cf.created_at<now()-interval '30 days')) trend,
   coalesce((select jsonb_agg(distinct qe.source_attribution) from pace_v2.quality_evidence qe where qe.operator_id=oq.id),'[]'::jsonb) attribution_states
  from pace_v2.site_admin_operator_quality_source oq left join pace_v2.customer_feedback cf on cf.operator_id=oq.id group by oq.id,oq.name,oq.quality_score
 ) q;

 select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'name',q.name,'average',q.average,'response_count',q.response_count,'trend',q.trend) order by q.name),'[]'::jsonb)
 into v_captains from(
  select c.id,trim(concat_ws(' ',c.first_name,c.last_name)) name,avg(cf.captain_rating) filter (where cf.captain_rating is not null) average,count(cf.captain_rating) response_count,
   (avg(cf.captain_rating) filter(where cf.captain_rating is not null and cf.created_at>=now()-interval '30 days'))-(avg(cf.captain_rating) filter(where cf.captain_rating is not null and cf.created_at>=now()-interval '60 days' and cf.created_at<now()-interval '30 days')) trend
  from pace_v2.captains c left join pace_v2.customer_feedback cf on cf.captain_id=c.id group by c.id,c.first_name,c.last_name
 ) q;

 select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'name',q.name,'average',q.average,'response_count',q.response_count,'trend',q.trend,'country_name',q.country_name,'country_average',q.country_average) order by q.name),'[]'::jsonb)
 into v_pickups from(
  select p.id,p.name,c.name country_name,avg(cf.pickup_rating) filter (where cf.pickup_rating is not null) average,count(cf.pickup_rating) response_count,
   (avg(cf.pickup_rating) filter(where cf.pickup_rating is not null and cf.created_at>=now()-interval '30 days'))-(avg(cf.pickup_rating) filter(where cf.pickup_rating is not null and cf.created_at>=now()-interval '60 days' and cf.created_at<now()-interval '30 days')) trend,
   (select avg(all_cf.pickup_rating) filter (where all_cf.pickup_rating is not null) from pace_v2.customer_feedback all_cf join pace_v2.pickup_points all_p on all_p.id=all_cf.pickup_id where all_p.country_id=p.country_id) country_average
  from pace_v2.pickup_points p join pace_v2.countries c on c.id=p.country_id left join pace_v2.customer_feedback cf on cf.pickup_id=p.id group by p.id,p.name,p.country_id,c.name
 ) q;

 select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'name',q.name,'average',q.average,'response_count',q.response_count,'trend',q.trend,'country_name',q.country_name,'country_average',q.country_average) order by q.name),'[]'::jsonb)
 into v_destinations from(
  select d.id,d.name,c.name country_name,avg(cf.destination_rating) filter (where cf.destination_rating is not null) average,count(cf.destination_rating) response_count,
   (avg(cf.destination_rating) filter(where cf.destination_rating is not null and cf.created_at>=now()-interval '30 days'))-(avg(cf.destination_rating) filter(where cf.destination_rating is not null and cf.created_at>=now()-interval '60 days' and cf.created_at<now()-interval '30 days')) trend,
   (select avg(all_cf.destination_rating) filter (where all_cf.destination_rating is not null) from pace_v2.customer_feedback all_cf join pace_v2.destinations all_d on all_d.id=all_cf.destination_id where all_d.country_id=d.country_id) country_average
  from pace_v2.destinations d join pace_v2.countries c on c.id=d.country_id left join pace_v2.customer_feedback cf on cf.destination_id=d.id group by d.id,d.name,d.country_id,c.name
 ) q;
 return jsonb_build_object('platform',v_platform,'operators',v_operators,'captains',v_captains,'pickups',v_pickups,'destinations',v_destinations);
end
$dashboard$;

create or replace function public.v2_site_admin_quality_evidence_page(p_offset integer,p_limit integer)
returns jsonb language plpgsql stable security definer set search_path=public,pace_v2,auth as $evidence$
declare v_items jsonb; v_total bigint; v_offset integer:=greatest(coalesce(p_offset,0),0); v_limit integer:=least(greatest(coalesce(p_limit,25),1),100);
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 select count(*) into v_total from pace_v2.customer_feedback;
 select coalesce(jsonb_agg(to_jsonb(page_row) order by page_row.created_at desc),'[]'::jsonb) into v_items from(
  select cf.id,cf.booking_id,concat_ws(' to ',pp.name,dst.name) route_name,o.name operator_name,
   cf.booking_experience_rating,cf.pace_shuttles_nps_score,cf.operator_rating,cf.captain_rating,cf.pickup_rating,cf.destination_rating,
   cf.went_well,cf.could_improve,cf.testimonial_consent,cf.created_at,
   coalesce((select string_agg(distinct qe.source_attribution,', ' order by qe.source_attribution) from pace_v2.quality_evidence qe where qe.feedback_id=cf.id),'unassigned') attribution_state
  from pace_v2.customer_feedback cf join pace_v2.operators o on o.id=cf.operator_id join pace_v2.pickup_points pp on pp.id=cf.pickup_id join pace_v2.destinations dst on dst.id=cf.destination_id
  order by cf.created_at desc,cf.id offset v_offset limit v_limit
 ) page_row;
 return jsonb_build_object('items',v_items,'total',v_total,'offset',v_offset,'limit',v_limit);
end
$evidence$;

revoke all on function public.v2_site_admin_quality_dashboard(),public.v2_site_admin_quality_evidence_page(integer,integer) from public,anon,authenticated;
grant execute on function public.v2_site_admin_quality_dashboard(),public.v2_site_admin_quality_evidence_page(integer,integer) to authenticated;

create or replace function pace_v2.add_feedback_email_first_name()
returns trigger language plpgsql security definer set search_path=pace_v2,public,auth as $metadata$
declare v_first_name text;
begin
 if new.template_code='post_journey_feedback' then
  select split_part(nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),''),' ',1) into v_first_name from pace_v2.bookings b where b.id=new.booking_id;
  new.metadata:=coalesce(new.metadata,'{}'::jsonb)||jsonb_build_object('first_name',v_first_name);
 end if;
 return new;
end
$metadata$;
revoke all on function pace_v2.add_feedback_email_first_name() from public,anon,authenticated;
drop trigger if exists customer_notifications_add_feedback_first_name on pace_v2.notifications;
create trigger customer_notifications_add_feedback_first_name before insert or update of metadata,template_code,booking_id on pace_v2.notifications for each row execute function pace_v2.add_feedback_email_first_name();
update pace_v2.notifications n set metadata=coalesce(n.metadata,'{}'::jsonb)||jsonb_build_object('first_name',split_part(nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),''),' ',1)) from pace_v2.bookings b where b.id=n.booking_id and n.template_code='post_journey_feedback';
