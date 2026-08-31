begin;

-- The seeded local fixture must contain two owners on one allocation plus role-linked
-- captains, an operator-only user, and a Site Admin. This test never targets a remote DB.
create temporary table private_journey_messaging_fixture(
  allocation_id uuid not null,departure_id uuid not null,booking_a_id uuid not null,booking_b_id uuid not null,
  owner_a_id uuid not null,owner_b_id uuid not null,captain_user_id uuid not null,other_captain_user_id uuid not null,
  operator_user_id uuid not null,site_admin_user_id uuid not null,conversation_a_id uuid,conversation_b_id uuid
) on commit drop;
grant select,update on private_journey_messaging_fixture to authenticated;
create temporary table private_journey_messaging_results(kind text primary key,observed integer not null) on commit drop;
grant select,insert on private_journey_messaging_results to authenticated;

insert into private_journey_messaging_fixture(
  allocation_id,departure_id,booking_a_id,booking_b_id,owner_a_id,owner_b_id,captain_user_id,other_captain_user_id,operator_user_id,site_admin_user_id
)
select ca.id,d.id,b_a.id,b_b.id,b_a.owner_id,b_b.owner_id,assigned_captain.auth_user_id,other_captain.auth_user_id,operator_user.user_id,site_admin.user_id
from pace_v2.confirmed_allocations ca
join pace_v2.departures d on d.id=ca.departure_id
join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
join lateral (
  select c.id,c.auth_user_id from pace_v2.captain_assignments a
  join pace_v2.captains c on c.id=a.captain_id and c.active and c.operator_id=ca.operator_id
  join pace_v2.captain_vehicle_types cvt on cvt.captain_id=c.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
  where a.confirmed_allocation_id=ca.id and a.active and c.auth_user_id is not null
    and not exists(select 1 from pace_v2.profiles p where p.user_id=c.auth_user_id and p.platform_role='site_admin')
    and not exists(select 1 from pace_v2.operator_memberships om where om.user_id=c.auth_user_id)
    and not exists(select 1 from pace_v2.bookings b where pace_v2.booking_owner_user_id(b.id)=c.auth_user_id)
  order by c.id limit 1
) assigned_captain on true
join lateral (
  select b.id,pace_v2.booking_owner_user_id(b.id) as owner_id from pace_v2.booking_allocations ba join pace_v2.bookings b on b.id=ba.booking_id
  where ba.vehicle_consideration_id=ca.consideration_id and pace_v2.booking_owner_user_id(b.id) is not null
    and pace_v2.is_active_paid_journey_booking(b.id,null)
    and not exists(select 1 from pace_v2.profiles p where p.user_id=pace_v2.booking_owner_user_id(b.id) and p.platform_role='site_admin')
    and not exists(select 1 from pace_v2.operator_memberships om where om.user_id=pace_v2.booking_owner_user_id(b.id))
    and not exists(select 1 from pace_v2.captains c where c.auth_user_id=pace_v2.booking_owner_user_id(b.id))
  order by b.id limit 1
) b_a on true
join lateral (
  select b.id,pace_v2.booking_owner_user_id(b.id) as owner_id from pace_v2.booking_allocations ba join pace_v2.bookings b on b.id=ba.booking_id
  where ba.vehicle_consideration_id=ca.consideration_id and b.id<>b_a.id and pace_v2.booking_owner_user_id(b.id) is not null and pace_v2.booking_owner_user_id(b.id)<>b_a.owner_id
    and pace_v2.is_active_paid_journey_booking(b.id,null)
    and not exists(select 1 from pace_v2.profiles p where p.user_id=pace_v2.booking_owner_user_id(b.id) and p.platform_role='site_admin')
    and not exists(select 1 from pace_v2.operator_memberships om where om.user_id=pace_v2.booking_owner_user_id(b.id))
    and not exists(select 1 from pace_v2.captains c where c.auth_user_id=pace_v2.booking_owner_user_id(b.id))
  order by b.id limit 1
) b_b on true
join lateral (
  select c.auth_user_id from pace_v2.captains c where c.active and c.auth_user_id is not null and c.auth_user_id<>assigned_captain.auth_user_id
    and not exists(select 1 from pace_v2.profiles p where p.user_id=c.auth_user_id and p.platform_role='site_admin')
    and not exists(select 1 from pace_v2.operator_memberships om where om.user_id=c.auth_user_id)
    and not exists(select 1 from pace_v2.bookings b where pace_v2.booking_owner_user_id(b.id)=c.auth_user_id)
    and not exists(select 1 from pace_v2.captains any_c join pace_v2.captain_assignments a on a.captain_id=any_c.id and a.active where any_c.auth_user_id=c.auth_user_id and a.confirmed_allocation_id=ca.id)
  order by c.id limit 1
) other_captain on true
join lateral (
  select om.user_id from pace_v2.operator_memberships om
  left join pace_v2.profiles p on p.user_id=om.user_id
  where om.active and not exists(select 1 from pace_v2.captains c where c.auth_user_id=om.user_id) and coalesce(p.platform_role::text,'customer')<>'site_admin'
    and om.user_id not in (b_a.owner_id,b_b.owner_id,assigned_captain.auth_user_id,other_captain.auth_user_id)
    and not exists(select 1 from pace_v2.bookings b where pace_v2.booking_owner_user_id(b.id)=om.user_id)
  order by om.user_id limit 1
) operator_user on true
join lateral (select p.user_id from pace_v2.profiles p where p.platform_role='site_admin' and p.user_id not in (b_a.owner_id,b_b.owner_id,assigned_captain.auth_user_id,other_captain.auth_user_id,operator_user.user_id) and not exists(select 1 from pace_v2.captains c where c.auth_user_id=p.user_id) and not exists(select 1 from pace_v2.operator_memberships om where om.user_id=p.user_id) and not exists(select 1 from pace_v2.bookings b where pace_v2.booking_owner_user_id(b.id)=p.user_id) order by p.user_id limit 1) site_admin on true
where ca.status='confirmed' order by ca.id limit 1;

do $$ begin
  if not exists(select 1 from private_journey_messaging_fixture) then raise exception 'fixture: two paid active booking owners, assigned and other captains, operator-only user, and Site Admin are required'; end if;
  if exists(select 1 from private_journey_messaging_fixture f where f.owner_a_id=f.owner_b_id or f.owner_a_id in (f.captain_user_id,f.other_captain_user_id,f.operator_user_id,f.site_admin_user_id) or f.owner_b_id in (f.captain_user_id,f.other_captain_user_id,f.operator_user_id,f.site_admin_user_id) or f.captain_user_id in (f.other_captain_user_id,f.operator_user_id,f.site_admin_user_id) or f.other_captain_user_id in (f.operator_user_id,f.site_admin_user_id) or f.operator_user_id=f.site_admin_user_id) then raise exception 'fixture identities overlap'; end if;
end $$;

update pace_v2.departures d set scheduled_departure_ts=now()+interval '24 hours',scheduled_arrival_ts=now()+interval '26 hours',t72_ts=now()-interval '48 hours',t24_ts=now(),local_departure_date=((now()+interval '24 hours') at time zone d.trip_timezone)::date,actual_arrival_ts=null
from private_journey_messaging_fixture f where d.id=f.departure_id;

select set_config('request.jwt.claim.sub',(select owner_a_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
update private_journey_messaging_fixture set conversation_a_id=public.v2_customer_open_captain_conversation(booking_a_id,'Party A private message');
reset role;
select set_config('request.jwt.claim.sub',(select owner_b_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
update private_journey_messaging_fixture set conversation_b_id=public.v2_customer_open_captain_conversation(booking_b_id,'Party B private message');
reset role;

-- A valid upsert reopens a closed thread coherently and keeps the same private identity.
update pace_v2.journey_conversations jc set status='closed',closed_at=now()
from private_journey_messaging_fixture f where jc.id=f.conversation_a_id;
select set_config('request.jwt.claim.sub',(select owner_a_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
update private_journey_messaging_fixture set conversation_a_id=public.v2_customer_open_captain_conversation(booking_a_id,'Party A reopen message');
reset role;
do $$ begin
  if not exists(select 1 from pace_v2.journey_conversations jc join private_journey_messaging_fixture f on f.conversation_a_id=jc.id where jc.status='open' and jc.closed_at is null) then raise exception 'reopened conversation did not clear closed state'; end if;
end $$;

-- T-24 is inclusive: all four write RPCs work at the exact opening boundary.
select set_config('request.jwt.claim.sub',(select owner_a_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
select public.v2_customer_send_captain_message((select conversation_a_id from private_journey_messaging_fixture),'Customer A exact-T-24 follow-up');
reset role;
select set_config('request.jwt.claim.sub',(select owner_b_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
select public.v2_customer_send_captain_message((select conversation_b_id from private_journey_messaging_fixture),'Customer B exact-T-24 follow-up');
reset role;
select set_config('request.jwt.claim.sub',(select captain_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
select public.v2_captain_reply_to_party((select conversation_a_id from private_journey_messaging_fixture),'Captain exact-T-24 reply','operational');
reset role;
select set_config('request.jwt.claim.sub',(select site_admin_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
select public.v2_site_admin_reply_journey_conversation((select conversation_b_id from private_journey_messaging_fixture),'Site Admin exact-T-24 reply','operational');
reset role;

-- No cross-party or unauthorised write may succeed while the window is open.
select set_config('request.jwt.claim.sub',(select owner_b_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin begin perform public.v2_customer_send_captain_message((select conversation_a_id from private_journey_messaging_fixture),'cross-party denial'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey conversation not found' then raise exception 'customer B could write customer A conversation: %',v_error; end if; end $$;
do $$ declare v_error text; begin begin perform public.v2_customer_open_captain_conversation((select booking_a_id from private_journey_messaging_fixture),'cross-party open denial'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'booking does not have an eligible assigned captain' then raise exception 'customer B could open customer A booking: %',v_error; end if; end $$;
do $$ declare v_error text; begin begin perform public.v2_captain_reply_to_party((select conversation_a_id from private_journey_messaging_fixture),'customer captain denial','operational'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey conversation not assigned to captain' then raise exception 'customer could use captain reply: %',v_error; end if; end $$;
do $$ declare v_error text; begin begin perform public.v2_site_admin_reply_journey_conversation((select conversation_a_id from private_journey_messaging_fixture),'non-admin admin denial','operational'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'site admin required' then raise exception 'non-admin could use Site Admin reply: %',v_error; end if; end $$;
reset role;
select set_config('request.jwt.claim.sub',(select other_captain_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin begin perform public.v2_captain_reply_to_party((select conversation_a_id from private_journey_messaging_fixture),'other captain denial','operational'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey conversation not assigned to captain' then raise exception 'other captain could write private conversation: %',v_error; end if; end $$;
reset role;
select set_config('request.jwt.claim.sub',(select operator_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin begin perform public.v2_captain_reply_to_party((select conversation_a_id from private_journey_messaging_fixture),'operator denial','operational'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey conversation not assigned to captain' then raise exception 'operator-only user could write private conversation: %',v_error; end if; end $$;
reset role;

select set_config('request.jwt.claim.sub',(select owner_a_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
insert into private_journey_messaging_results select 'owner_a_conversations',count(*)::integer from public.v2_customer_my_journey_conversations where id in (select conversation_a_id from private_journey_messaging_fixture union all select conversation_b_id from private_journey_messaging_fixture);
insert into private_journey_messaging_results select 'owner_a_messages',count(*)::integer from public.v2_customer_my_journey_messages where conversation_id in (select conversation_a_id from private_journey_messaging_fixture union all select conversation_b_id from private_journey_messaging_fixture);
do $$ declare v_state text; begin begin perform sender_user_id from pace_v2.journey_conversation_messages where conversation_id=(select conversation_a_id from private_journey_messaging_fixture); exception when others then v_state:=sqlstate; end; if v_state is distinct from '42501' then raise exception 'authenticated user could select hidden sender_user_id: %',v_state; end if; end $$;
reset role;
select set_config('request.jwt.claim.sub',(select owner_b_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
insert into private_journey_messaging_results select 'owner_b_conversations',count(*)::integer from public.v2_customer_my_journey_conversations where id in (select conversation_a_id from private_journey_messaging_fixture union all select conversation_b_id from private_journey_messaging_fixture);
insert into private_journey_messaging_results select 'owner_b_messages',count(*)::integer from public.v2_customer_my_journey_messages where conversation_id in (select conversation_a_id from private_journey_messaging_fixture union all select conversation_b_id from private_journey_messaging_fixture);
reset role;
select set_config('request.jwt.claim.sub',(select captain_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
insert into private_journey_messaging_results select 'assigned_captain_conversations',count(*)::integer from public.v2_captain_my_journey_conversations where id in (select conversation_a_id from private_journey_messaging_fixture union all select conversation_b_id from private_journey_messaging_fixture);
insert into private_journey_messaging_results select 'assigned_captain_messages',count(*)::integer from public.v2_captain_my_journey_messages where conversation_id in (select conversation_a_id from private_journey_messaging_fixture union all select conversation_b_id from private_journey_messaging_fixture);
reset role;
select set_config('request.jwt.claim.sub',(select other_captain_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
insert into private_journey_messaging_results select 'other_captain_conversations',count(*)::integer from public.v2_captain_my_journey_conversations where id in (select conversation_a_id from private_journey_messaging_fixture union all select conversation_b_id from private_journey_messaging_fixture);
insert into private_journey_messaging_results select 'other_captain_messages',count(*)::integer from public.v2_captain_my_journey_messages where conversation_id in (select conversation_a_id from private_journey_messaging_fixture union all select conversation_b_id from private_journey_messaging_fixture);
reset role;
select set_config('request.jwt.claim.sub',(select operator_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
insert into private_journey_messaging_results select 'operator_conversations',count(*)::integer from public.v2_captain_my_journey_conversations where id in (select conversation_a_id from private_journey_messaging_fixture union all select conversation_b_id from private_journey_messaging_fixture);
insert into private_journey_messaging_results select 'operator_messages',count(*)::integer from public.v2_captain_my_journey_messages where conversation_id in (select conversation_a_id from private_journey_messaging_fixture union all select conversation_b_id from private_journey_messaging_fixture);
reset role;
select set_config('request.jwt.claim.sub',(select site_admin_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
insert into private_journey_messaging_results select 'site_admin_conversations',count(*)::integer from public.v2_captain_my_journey_conversations where id in (select conversation_a_id from private_journey_messaging_fixture union all select conversation_b_id from private_journey_messaging_fixture);
insert into private_journey_messaging_results select 'site_admin_messages',count(*)::integer from public.v2_captain_my_journey_messages where conversation_id in (select conversation_a_id from private_journey_messaging_fixture union all select conversation_b_id from private_journey_messaging_fixture);
insert into private_journey_messaging_results select 'site_admin_customer_conversations',count(*)::integer from public.v2_customer_my_journey_conversations where id in (select conversation_a_id from private_journey_messaging_fixture union all select conversation_b_id from private_journey_messaging_fixture);
insert into private_journey_messaging_results select 'site_admin_customer_messages',count(*)::integer from public.v2_customer_my_journey_messages where conversation_id in (select conversation_a_id from private_journey_messaging_fixture union all select conversation_b_id from private_journey_messaging_fixture);
reset role;

-- One microsecond before T-24 must return the specific closed-window error.
update pace_v2.departures d set scheduled_departure_ts=now()+interval '24 hours 1 microsecond',scheduled_arrival_ts=now()+interval '26 hours 1 microsecond',t72_ts=now()-interval '47 hours 59 minutes 59.999999 seconds',t24_ts=now()+interval '1 microsecond',local_departure_date=((now()+interval '24 hours 1 microsecond') at time zone d.trip_timezone)::date,actual_arrival_ts=null from private_journey_messaging_fixture f where d.id=f.departure_id;
select set_config('request.jwt.claim.sub',(select owner_a_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin begin perform public.v2_customer_send_captain_message((select conversation_a_id from private_journey_messaging_fixture),'must fail before T-24'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey messaging window is closed' then raise exception 'before-T-24 error mismatch: %',v_error; end if; end $$;
do $$ declare v_error text; begin begin perform public.v2_customer_open_captain_conversation((select booking_a_id from private_journey_messaging_fixture),'must fail before T-24'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey messaging window is closed' then raise exception 'before-T-24 open error mismatch: %',v_error; end if; end $$;
reset role;
select set_config('request.jwt.claim.sub',(select captain_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin begin perform public.v2_captain_reply_to_party((select conversation_a_id from private_journey_messaging_fixture),'must fail before T-24','operational'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey messaging window is closed' then raise exception 'before-T-24 captain error mismatch: %',v_error; end if; end $$;
reset role;
select set_config('request.jwt.claim.sub',(select site_admin_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin begin perform public.v2_site_admin_reply_journey_conversation((select conversation_a_id from private_journey_messaging_fixture),'must fail before T-24','operational'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey messaging window is closed' then raise exception 'before-T-24 Site Admin error mismatch: %',v_error; end if; end $$;
reset role;

-- Scheduled-arrival fallback closes exactly at scheduled arrival + 12 hours, exclusively.
update pace_v2.departures d set scheduled_departure_ts=now()-interval '14 hours',scheduled_arrival_ts=now()-interval '12 hours',t72_ts=now()-interval '86 hours',t24_ts=now()-interval '38 hours',local_departure_date=((now()-interval '14 hours') at time zone d.trip_timezone)::date,actual_arrival_ts=null from private_journey_messaging_fixture f where d.id=f.departure_id;
do $$ declare v_allocation uuid:=(select allocation_id from private_journey_messaging_fixture); begin
  if pace_v2.journey_message_closes_at(v_allocation) is distinct from now() or pace_v2.is_journey_message_window_open(v_allocation,now()) then raise exception 'scheduled-arrival fallback close boundary is not exact/exclusive'; end if;
end $$;
select set_config('request.jwt.claim.sub',(select owner_a_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin begin perform public.v2_customer_send_captain_message((select conversation_a_id from private_journey_messaging_fixture),'must fail at scheduled fallback close'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey messaging window is closed' then raise exception 'scheduled fallback close error mismatch: %',v_error; end if; end $$;
do $$ declare v_error text; begin begin perform public.v2_customer_open_captain_conversation((select booking_a_id from private_journey_messaging_fixture),'must fail at scheduled fallback close'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey messaging window is closed' then raise exception 'scheduled fallback open error mismatch: %',v_error; end if; end $$;
reset role;
select set_config('request.jwt.claim.sub',(select captain_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin begin perform public.v2_captain_reply_to_party((select conversation_a_id from private_journey_messaging_fixture),'must fail at scheduled fallback close','operational'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey messaging window is closed' then raise exception 'scheduled fallback captain error mismatch: %',v_error; end if; end $$;
reset role;
select set_config('request.jwt.claim.sub',(select site_admin_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin begin perform public.v2_site_admin_reply_journey_conversation((select conversation_a_id from private_journey_messaging_fixture),'must fail at scheduled fallback close','operational'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey messaging window is closed' then raise exception 'scheduled fallback Site Admin error mismatch: %',v_error; end if; end $$;
reset role;

-- Actual-arrival + 4 hours takes precedence and is also an exclusive close boundary.
update pace_v2.departures d set scheduled_departure_ts=now()-interval '10 hours',scheduled_arrival_ts=now()-interval '8 hours',t72_ts=now()-interval '82 hours',t24_ts=now()-interval '34 hours',local_departure_date=((now()-interval '10 hours') at time zone d.trip_timezone)::date,actual_arrival_ts=now()-interval '4 hours' from private_journey_messaging_fixture f where d.id=f.departure_id;
do $$ declare v_allocation uuid:=(select allocation_id from private_journey_messaging_fixture); begin
  if pace_v2.journey_message_closes_at(v_allocation) is distinct from now() or pace_v2.is_journey_message_window_open(v_allocation,now()) then raise exception 'actual-arrival close boundary is not exact/exclusive'; end if;
end $$;
select set_config('request.jwt.claim.sub',(select owner_a_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin begin perform public.v2_customer_send_captain_message((select conversation_a_id from private_journey_messaging_fixture),'must fail at actual-arrival close'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey messaging window is closed' then raise exception 'actual-arrival customer send error mismatch: %',v_error; end if; end $$;
do $$ declare v_error text; begin begin perform public.v2_customer_open_captain_conversation((select booking_a_id from private_journey_messaging_fixture),'must fail at actual-arrival close'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey messaging window is closed' then raise exception 'actual-arrival customer open error mismatch: %',v_error; end if; end $$;
reset role;
select set_config('request.jwt.claim.sub',(select captain_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin begin perform public.v2_captain_reply_to_party((select conversation_a_id from private_journey_messaging_fixture),'must fail at actual-arrival close','operational'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey messaging window is closed' then raise exception 'actual-arrival captain error mismatch: %',v_error; end if; end $$;
reset role;
select set_config('request.jwt.claim.sub',(select site_admin_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin begin perform public.v2_site_admin_reply_journey_conversation((select conversation_a_id from private_journey_messaging_fixture),'must fail at actual-arrival close','operational'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey messaging window is closed' then raise exception 'actual-arrival close error mismatch: %',v_error; end if; end $$;
reset role;

-- An ineligible booking cannot be revived through captain or Site Admin write paths.
update pace_v2.departures d set scheduled_departure_ts=now()+interval '24 hours',scheduled_arrival_ts=now()+interval '26 hours',t72_ts=now()-interval '48 hours',t24_ts=now(),local_departure_date=((now()+interval '24 hours') at time zone d.trip_timezone)::date,actual_arrival_ts=null from private_journey_messaging_fixture f where d.id=f.departure_id;
update pace_v2.bookings b set status='cancelled' from private_journey_messaging_fixture f where b.id=f.booking_a_id;
select set_config('request.jwt.claim.sub',(select captain_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin begin perform public.v2_captain_reply_to_party((select conversation_a_id from private_journey_messaging_fixture),'must not revive cancelled booking','operational'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey conversation not assigned to captain' then raise exception 'captain revived cancelled booking: %',v_error; end if; end $$;
reset role;
select set_config('request.jwt.claim.sub',(select site_admin_user_id::text from private_journey_messaging_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin begin perform public.v2_site_admin_reply_journey_conversation((select conversation_a_id from private_journey_messaging_fixture),'must not revive cancelled booking','operational'); exception when others then v_error:=sqlerrm; end; if v_error is distinct from 'journey conversation not found' then raise exception 'Site Admin revived cancelled booking: %',v_error; end if; end $$;
reset role;

-- Anonymous sessions actually attempt a protected read and RPC; grants are not merely inspected.
grant select on private_journey_messaging_fixture to anon;
select set_config('request.jwt.claim.sub','',true);
set local role anon;
do $$ declare v_read_state text; v_rpc_state text; begin
  begin perform 1 from public.v2_customer_my_journey_conversations limit 1; exception when others then v_read_state:=sqlstate; end;
  begin perform public.v2_customer_send_captain_message((select conversation_a_id from private_journey_messaging_fixture),'anonymous denial'); exception when others then v_rpc_state:=sqlstate; end;
  if v_read_state is distinct from '42501' or v_rpc_state is distinct from '42501' then raise exception 'anonymous protected read/RPC was not denied: %, %',v_read_state,v_rpc_state; end if;
end $$;
reset role;

do $$ begin
  if (select observed from private_journey_messaging_results where kind='owner_a_conversations')<>1 or (select observed from private_journey_messaging_results where kind='owner_a_messages')<>4 or (select observed from private_journey_messaging_results where kind='owner_b_conversations')<>1 or (select observed from private_journey_messaging_results where kind='owner_b_messages')<>3 or (select observed from private_journey_messaging_results where kind='assigned_captain_conversations')<>2 or (select observed from private_journey_messaging_results where kind='assigned_captain_messages')<>7 or (select observed from private_journey_messaging_results where kind='other_captain_conversations')<>0 or (select observed from private_journey_messaging_results where kind='other_captain_messages')<>0 or (select observed from private_journey_messaging_results where kind='operator_conversations')<>0 or (select observed from private_journey_messaging_results where kind='operator_messages')<>0 or (select observed from private_journey_messaging_results where kind='site_admin_conversations')<>2 or (select observed from private_journey_messaging_results where kind='site_admin_messages')<>7 or (select observed from private_journey_messaging_results where kind='site_admin_customer_conversations')<>2 or (select observed from private_journey_messaging_results where kind='site_admin_customer_messages')<>7 then raise exception 'private journey messaging visibility isolation failed'; end if;
  if has_table_privilege('anon','public.v2_customer_my_journey_conversations','select') or has_table_privilege('anon','public.v2_customer_my_journey_messages','select') or has_table_privilege('anon','public.v2_captain_my_journey_conversations','select') or has_table_privilege('anon','public.v2_captain_my_journey_messages','select') or has_function_privilege('anon','public.v2_customer_open_captain_conversation(uuid,text)','execute') or has_function_privilege('anon','public.v2_customer_send_captain_message(uuid,text)','execute') or has_function_privilege('anon','public.v2_captain_reply_to_party(uuid,text,text)','execute') or has_function_privilege('anon','public.v2_site_admin_reply_journey_conversation(uuid,text,text)','execute') then raise exception 'anonymous role received private journey messaging access'; end if;
end $$;

rollback;
