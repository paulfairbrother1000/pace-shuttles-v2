begin;

create temporary table admin_reporting_fixture(
 site_admin_user_id uuid,
 customer_user_id uuid,
 operator_user_id uuid,
 alert_id uuid,
 expected_nps_count bigint,
 expected_operator_count integer,
 expected_feedback_count bigint
) on commit drop;
grant select on admin_reporting_fixture to authenticated;
insert into admin_reporting_fixture(site_admin_user_id,customer_user_id,operator_user_id,alert_id)
select admin_user.user_id,customer_user.user_id,operator_user.user_id,gen_random_uuid()
from lateral(select p.user_id from pace_v2.profiles p where p.platform_role='site_admin' order by p.user_id limit 1) admin_user
cross join lateral(select pace_v2.booking_owner_user_id(b.id) user_id from pace_v2.bookings b where pace_v2.booking_owner_user_id(b.id) is not null and not exists(select 1 from pace_v2.profiles p where p.user_id=pace_v2.booking_owner_user_id(b.id) and p.platform_role='site_admin') order by b.id limit 1) customer_user
cross join lateral(select om.user_id from pace_v2.operator_memberships om left join pace_v2.profiles p on p.user_id=om.user_id where om.active and coalesce(p.platform_role::text,'customer')<>'site_admin' order by om.user_id limit 1) operator_user;
do $$ begin if not exists(select 1 from admin_reporting_fixture) then raise exception 'fixture requires Site Admin, customer and operator identities'; end if; end $$;
insert into pace_v2.operational_alerts(id,exception_key,exception_type,severity,details) select alert_id,'task7-reporting-fixture','task7_reporting','high','{}'::jsonb from admin_reporting_fixture;
do $$ declare v_id uuid; begin
 if (select count(*) from pace_v2.customer_feedback)<2 then raise exception 'fixture requires two feedback rows to verify the second evidence page'; end if;
 select id into v_id from pace_v2.customer_feedback order by id limit 1;
 if v_id is null then raise exception 'fixture requires one feedback row for legacy-null reporting'; end if;
 update pace_v2.customer_feedback set feedback_schema_version=1,booking_experience_rating=null,pace_shuttles_nps_score=null,operator_rating=null,captain_rating=null,pickup_rating=null,destination_rating=null,operator_id=null,captain_id=null,pickup_id=null,destination_id=null,created_at=clock_timestamp()+interval '2 days' where id=v_id;
end $$;
update admin_reporting_fixture set
 expected_nps_count=(select count(pace_shuttles_nps_score) from pace_v2.customer_feedback),
 expected_operator_count=(select count(*)::integer from pace_v2.site_admin_operator_quality_source),
 expected_feedback_count=(select count(*) from pace_v2.customer_feedback);

select set_config('request.jwt.claim.sub',(select site_admin_user_id::text from admin_reporting_fixture),true);
set local role authenticated;
do $$ begin
 if not exists(select 1 from public.v2_admin_operational_alerts where id=(select alert_id from admin_reporting_fixture)) then raise exception 'Site Admin projection hid an alert'; end if;
 perform 1 from public.v2_admin_journey_conversations limit 1;
 perform 1 from public.v2_admin_journey_messages limit 1;
 perform 1 from public.v2_admin_journey_broadcast_deliveries limit 1;
 if public.v2_site_admin_quality_dashboard() is null then raise exception 'Site Admin quality dashboard returned null'; end if;
 if (public.v2_site_admin_quality_dashboard()->'platform'->>'response_count')::bigint is distinct from (select expected_nps_count from admin_reporting_fixture) then raise exception 'legacy null ratings were included'; end if;
 if jsonb_array_length(public.v2_site_admin_quality_dashboard()->'operators') is distinct from (select expected_operator_count from admin_reporting_fixture) then raise exception 'protected operator source was not completely represented'; end if;
 if (public.v2_site_admin_quality_evidence_page(0,1)->>'total')::bigint is distinct from (select expected_feedback_count from admin_reporting_fixture) then raise exception 'nullable legacy target changed the evidence count base'; end if;
 if public.v2_site_admin_quality_evidence_page(0,1)->'items'->0->>'operator_id' is not null
  or public.v2_site_admin_quality_evidence_page(0,1)->'items'->0->>'captain_id' is not null
  or public.v2_site_admin_quality_evidence_page(0,1)->'items'->0->>'pickup_id' is not null
  or public.v2_site_admin_quality_evidence_page(0,1)->'items'->0->>'destination_id' is not null then raise exception 'nullable legacy target was not retained on the first evidence page'; end if;
 if not ((public.v2_site_admin_quality_evidence_page(0,1)->'items'->0) ?& array['operator_id','operator_name','captain_id','captain_name','pickup_id','pickup_name','destination_id','destination_name']) then raise exception 'dimension identity keys are missing from evidence'; end if;
 if jsonb_array_length(public.v2_site_admin_quality_evidence_page(1,1)->'items')<>1 then raise exception 'second evidence page was not returned'; end if;
 if public.v2_site_admin_quality_evidence_page(0,1)->'items'->0->>'id'=public.v2_site_admin_quality_evidence_page(1,1)->'items'->0->>'id' then raise exception 'second evidence page repeated the first row'; end if;
end $$;
reset role;

select set_config('request.jwt.claim.sub',(select customer_user_id::text from admin_reporting_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin
 if exists(select 1 from public.v2_admin_operational_alerts)
  or exists(select 1 from public.v2_admin_journey_conversations)
  or exists(select 1 from public.v2_admin_journey_messages)
  or exists(select 1 from public.v2_admin_journey_broadcast_deliveries) then raise exception 'customer could see Site Admin projection rows'; end if;
 begin perform public.v2_site_admin_quality_dashboard(); exception when others then v_error:=sqlerrm; end;
 if v_error is distinct from 'site admin required' then raise exception 'customer quality denial mismatch: %',v_error; end if;
 v_error:=null;
 begin perform public.v2_site_admin_quality_evidence_page(0,1); exception when others then v_error:=sqlerrm; end;
 if v_error is distinct from 'site admin required' then raise exception 'customer evidence denial mismatch: %',v_error; end if;
end $$;
reset role;

select set_config('request.jwt.claim.sub',(select operator_user_id::text from admin_reporting_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin
 if exists(select 1 from public.v2_admin_operational_alerts)
  or exists(select 1 from public.v2_admin_journey_conversations)
  or exists(select 1 from public.v2_admin_journey_messages)
  or exists(select 1 from public.v2_admin_journey_broadcast_deliveries) then raise exception 'operator could see Site Admin projection rows'; end if;
 begin perform public.v2_site_admin_quality_dashboard(); exception when others then v_error:=sqlerrm; end;
 if v_error is distinct from 'site admin required' then raise exception 'operator quality denial mismatch: %',v_error; end if;
 v_error:=null;
 begin perform public.v2_site_admin_quality_evidence_page(0,1); exception when others then v_error:=sqlerrm; end;
 if v_error is distinct from 'site admin required' then raise exception 'operator evidence denial mismatch: %',v_error; end if;
end $$;
reset role;

set local role anon;
do $$ declare v_error text; begin
 begin perform * from public.v2_admin_operational_alerts; exception when others then v_error:=sqlstate; end;
 if v_error is distinct from '42501' then raise exception 'anonymous role could read Site Admin projections: %',v_error; end if;
end $$;
reset role;

rollback;
