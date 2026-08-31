begin;

-- Catalog contract for every SECURITY DEFINER introduced by Tasks 2-7. Internal
-- helpers/triggers remain non-executable, browser RPCs authenticate/authorize in
-- their bodies, and scheduling/delivery RPCs are service-role-only.
create temporary table journey_communications_security_functions(
  signature text primary key,
  access_kind text not null check(access_kind in('internal','trigger','authenticated','site_admin','service_role'))
) on commit drop;

insert into journey_communications_security_functions(signature,access_kind) values
 ('public.v2_system_schedule_t24_journey_notifications(timestamp with time zone)','service_role'),
 ('pace_v2.is_active_paid_journey_booking(uuid,uuid)','internal'),
 ('pace_v2.can_access_journey_conversation(uuid,text)','authenticated'),
 ('pace_v2.authorized_journey_message_window(uuid,text)','authenticated'),
 ('public.v2_customer_open_captain_conversation(uuid,text)','authenticated'),
 ('public.v2_customer_send_captain_message(uuid,text)','authenticated'),
 ('public.v2_captain_reply_to_party(uuid,text,text)','authenticated'),
 ('public.v2_site_admin_reply_journey_conversation(uuid,text,text)','site_admin'),
 ('public.v2_captain_broadcast_to_parties(uuid,text,text,uuid)','authenticated'),
 ('public.v2_system_claim_due_customer_emails_with_metadata(integer)','service_role'),
 ('public.v2_system_mark_journey_broadcast_email_sent(uuid,uuid,text)','service_role'),
 ('public.v2_system_mark_journey_broadcast_email_failed(uuid,uuid,text)','service_role'),
 ('public.v2_mark_journey_conversation_read(uuid,text)','authenticated'),
 ('pace_v2.authorized_customer_booking_message_window(uuid)','internal'),
 ('pace_v2.authorized_journey_conversation_unread_count(uuid,text)','authenticated'),
 ('pace_v2.authorized_captain_allocation_message_window(uuid)','authenticated'),
 ('public.v2_customer_my_journey_message_windows()','authenticated'),
 ('public.v2_system_schedule_feedback_requests(timestamp with time zone,integer)','service_role'),
 ('public.v2_customer_submit_feedback(uuid,integer,integer,integer,integer,integer,integer,text,text,boolean)','authenticated'),
 ('public.v2_site_admin_quality_dashboard()','site_admin'),
 ('public.v2_site_admin_quality_evidence_page(integer,integer)','site_admin'),
 ('pace_v2.add_feedback_email_first_name()','trigger');

do $security_definers$
declare
  v_expected record;
  v_oid oid;
  v_proc pg_proc%rowtype;
  v_public_execute boolean;
begin
  for v_expected in select * from journey_communications_security_functions order by signature loop
    v_oid:=to_regprocedure(v_expected.signature);
    if v_oid is null then raise exception 'release security function missing: %',v_expected.signature; end if;
    select * into strict v_proc from pg_proc where oid=v_oid;
    if not v_proc.prosecdef then raise exception '% must be SECURITY DEFINER',v_expected.signature; end if;
    if v_proc.proconfig is null or array_to_string(v_proc.proconfig,',') not like '%search_path=%' then
      raise exception '% lacks a fixed search_path',v_expected.signature;
    end if;
    select exists(
      select 1
      from aclexplode(coalesce(v_proc.proacl,acldefault('f',v_proc.proowner))) acl
      where acl.grantee=0 and acl.privilege_type='EXECUTE'
    ) into v_public_execute;
    if v_public_execute or has_function_privilege('anon',v_oid,'execute') then
      raise exception '% is executable by PUBLIC or anon',v_expected.signature;
    end if;

    if v_expected.access_kind='service_role' then
      if has_function_privilege('authenticated',v_oid,'execute')
        or not has_function_privilege('service_role',v_oid,'execute') then
        raise exception '% is not service-role-only',v_expected.signature;
      end if;
    elsif v_expected.access_kind='authenticated' then
      if not has_function_privilege('authenticated',v_oid,'execute') then
        raise exception '% is not available to authenticated callers',v_expected.signature;
      end if;
      if v_proc.prosrc !~* '(auth[.]uid[(]|can_access_journey_conversation|authorized_customer_booking_message_window)' then
        raise exception '% lacks an internal authenticated-user/ownership guard',v_expected.signature;
      end if;
    elsif v_expected.access_kind='site_admin' then
      if not has_function_privilege('authenticated',v_oid,'execute') or v_proc.prosrc !~* 'is_site_admin[(]' then
        raise exception '% lacks its internal Site Admin guard',v_expected.signature;
      end if;
    else
      if has_function_privilege('authenticated',v_oid,'execute') then
        raise exception '% internal function is client executable',v_expected.signature;
      end if;
      if v_expected.access_kind='trigger' and v_proc.prorettype<>'trigger'::regtype then
        raise exception '% is not trigger-only',v_expected.signature;
      end if;
    end if;
  end loop;
end
$security_definers$;

-- New tables fail closed. Authenticated identities receive only the column-level
-- SELECT grants used by security-invoker projections; all writes remain RPC-only.
do $table_security$
declare
  v_table text;
  v_oid regclass;
begin
  foreach v_table in array array[
    'journey_conversations','journey_conversation_messages','journey_broadcast_deliveries','operational_alerts',
    'journey_broadcast_requests','journey_message_read_states','customer_feedback','quality_configuration',
    'quality_evidence','platform_quality_history','captain_quality_history','pickup_quality_history','destination_quality_history'
  ] loop
    v_oid:=to_regclass('pace_v2.'||v_table);
    if v_oid is null then raise exception 'protected release table missing: pace_v2.%',v_table; end if;
    if not (select relrowsecurity from pg_class where oid=v_oid) then raise exception 'pace_v2.% has RLS disabled',v_table; end if;
    if has_table_privilege('anon',v_oid,'select') or has_table_privilege('anon',v_oid,'insert')
      or has_table_privilege('anon',v_oid,'update') or has_table_privilege('anon',v_oid,'delete') then
      raise exception 'anonymous table access remains on pace_v2.%',v_table;
    end if;
    if has_table_privilege('authenticated',v_oid,'insert') or has_table_privilege('authenticated',v_oid,'update')
      or has_table_privilege('authenticated',v_oid,'delete') then
      raise exception 'authenticated direct write remains on pace_v2.%',v_table;
    end if;
  end loop;
end
$table_security$;

do $view_security$
declare
  v_view text;
begin
  foreach v_view in array array[
    'v2_customer_my_journey_conversations','v2_customer_my_journey_messages',
    'v2_captain_my_journey_conversations','v2_captain_my_journey_messages',
    'v2_captain_my_journey_message_windows'
  ] loop
    if to_regclass('public.'||v_view) is null then raise exception 'protected release view missing: public.%',v_view; end if;
    if has_table_privilege('anon','public.'||v_view,'select') then raise exception 'anonymous read remains on public.%',v_view; end if;
    if not has_table_privilege('authenticated','public.'||v_view,'select') then raise exception 'authenticated read missing on public.%',v_view; end if;
    if not coalesce((select reloptions @> array['security_invoker=true'] from pg_class where oid=('public.'||v_view)::regclass),false) then
      raise exception 'public.% is not security_invoker',v_view;
    end if;
  end loop;
  foreach v_view in array array[
    'v2_admin_operational_alerts','v2_admin_journey_conversations','v2_admin_journey_messages','v2_admin_journey_broadcast_deliveries'
  ] loop
    if to_regclass('public.'||v_view) is null then raise exception 'Site Admin release view missing: public.%',v_view; end if;
    if has_table_privilege('anon','public.'||v_view,'select') then raise exception 'anonymous read remains on public.%',v_view; end if;
    if pg_get_viewdef(('public.'||v_view)::regclass,true) !~* 'is_site_admin[(][)]' then
      raise exception 'public.% lacks its internal Site Admin predicate',v_view;
    end if;
  end loop;
end
$view_security$;

-- Actual role matrix. The approved local/preview seed must supply pure, distinct
-- customer/captain/operator/admin identities on one eligible two-party allocation.
create temporary table journey_communications_security_fixture(
  allocation_id uuid not null,
  departure_id uuid not null,
  booking_a_id uuid not null,
  booking_b_id uuid not null,
  owner_a_id uuid not null,
  owner_b_id uuid not null,
  captain_user_id uuid not null,
  other_captain_user_id uuid not null,
  operator_user_id uuid not null,
  site_admin_user_id uuid not null,
  conversation_a_id uuid,
  conversation_b_id uuid,
  broadcast_request_id uuid not null default gen_random_uuid(),
  broadcast_source_id uuid,
  feedback_a_id uuid,
  feedback_b_id uuid
) on commit drop;
grant select,update on journey_communications_security_fixture to authenticated;
-- The anonymous checks need only fixture IDs; granting this transaction-local
-- table prevents a fixture lookup denial from masquerading as an RPC denial.
grant select on journey_communications_security_fixture to anon;

insert into journey_communications_security_fixture(
  allocation_id,departure_id,booking_a_id,booking_b_id,owner_a_id,owner_b_id,
  captain_user_id,other_captain_user_id,operator_user_id,site_admin_user_id
)
select ca.id,d.id,b_a.id,b_b.id,b_a.owner_id,b_b.owner_id,
  assigned_captain.auth_user_id,other_captain.auth_user_id,operator_user.user_id,site_admin.user_id
from pace_v2.confirmed_allocations ca
join pace_v2.departures d on d.id=ca.departure_id
join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
join lateral(
  select c.id,c.auth_user_id from pace_v2.captain_assignments a
  join pace_v2.captains c on c.id=a.captain_id and c.active and c.operator_id=ca.operator_id
  join pace_v2.captain_vehicle_types cvt on cvt.captain_id=c.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
  where a.confirmed_allocation_id=ca.id and a.active and c.auth_user_id is not null
    and not exists(select 1 from pace_v2.profiles p where p.user_id=c.auth_user_id and p.platform_role='site_admin')
    and not exists(select 1 from pace_v2.operator_memberships om where om.user_id=c.auth_user_id)
    and not exists(select 1 from pace_v2.bookings b where pace_v2.booking_owner_user_id(b.id)=c.auth_user_id)
  order by c.id limit 1
) assigned_captain on true
join lateral(
  select b.id,pace_v2.booking_owner_user_id(b.id) owner_id
  from pace_v2.booking_allocations ba join pace_v2.bookings b on b.id=ba.booking_id
  where ba.vehicle_consideration_id=ca.consideration_id and pace_v2.booking_owner_user_id(b.id) is not null
    and pace_v2.is_active_paid_journey_booking(b.id,null)
    and not exists(select 1 from pace_v2.profiles p where p.user_id=pace_v2.booking_owner_user_id(b.id) and p.platform_role='site_admin')
    and not exists(select 1 from pace_v2.operator_memberships om where om.user_id=pace_v2.booking_owner_user_id(b.id))
    and not exists(select 1 from pace_v2.captains c where c.auth_user_id=pace_v2.booking_owner_user_id(b.id))
  order by b.id limit 1
) b_a on true
join lateral(
  select b.id,pace_v2.booking_owner_user_id(b.id) owner_id
  from pace_v2.booking_allocations ba join pace_v2.bookings b on b.id=ba.booking_id
  where ba.vehicle_consideration_id=ca.consideration_id and b.id<>b_a.id
    and pace_v2.booking_owner_user_id(b.id) is not null
    and pace_v2.booking_owner_user_id(b.id)<>b_a.owner_id
    and pace_v2.is_active_paid_journey_booking(b.id,null)
    and not exists(select 1 from pace_v2.profiles p where p.user_id=pace_v2.booking_owner_user_id(b.id) and p.platform_role='site_admin')
    and not exists(select 1 from pace_v2.operator_memberships om where om.user_id=pace_v2.booking_owner_user_id(b.id))
    and not exists(select 1 from pace_v2.captains c where c.auth_user_id=pace_v2.booking_owner_user_id(b.id))
  order by b.id limit 1
) b_b on true
join lateral(
  select c.auth_user_id from pace_v2.captains c
  where c.active and c.auth_user_id is not null and c.auth_user_id<>assigned_captain.auth_user_id
    and not exists(select 1 from pace_v2.profiles p where p.user_id=c.auth_user_id and p.platform_role='site_admin')
    and not exists(select 1 from pace_v2.operator_memberships om where om.user_id=c.auth_user_id)
    and not exists(select 1 from pace_v2.bookings b where pace_v2.booking_owner_user_id(b.id)=c.auth_user_id)
    and not exists(select 1 from pace_v2.captains any_c join pace_v2.captain_assignments a on a.captain_id=any_c.id and a.active where any_c.auth_user_id=c.auth_user_id and a.confirmed_allocation_id=ca.id)
  order by c.id limit 1
) other_captain on true
join lateral(
  select om.user_id from pace_v2.operator_memberships om left join pace_v2.profiles p on p.user_id=om.user_id
  where om.active and not exists(select 1 from pace_v2.captains c where c.auth_user_id=om.user_id)
    and coalesce(p.platform_role::text,'customer')<>'site_admin'
    and om.user_id not in(b_a.owner_id,b_b.owner_id,assigned_captain.auth_user_id,other_captain.auth_user_id)
    and not exists(select 1 from pace_v2.bookings b where pace_v2.booking_owner_user_id(b.id)=om.user_id)
  order by om.user_id limit 1
) operator_user on true
join lateral(
  select p.user_id from pace_v2.profiles p
  where p.platform_role='site_admin'
    and p.user_id not in(b_a.owner_id,b_b.owner_id,assigned_captain.auth_user_id,other_captain.auth_user_id,operator_user.user_id)
    and not exists(select 1 from pace_v2.captains c where c.auth_user_id=p.user_id)
    and not exists(select 1 from pace_v2.operator_memberships om where om.user_id=p.user_id)
    and not exists(select 1 from pace_v2.bookings b where pace_v2.booking_owner_user_id(b.id)=p.user_id)
  order by p.user_id limit 1
) site_admin on true
where ca.status='confirmed'
order by ca.id limit 1;

do $$ begin
  if not exists(select 1 from journey_communications_security_fixture) then
    raise exception 'fixture requires two pure paid customers, assigned/other captains, operator-only user, and Site Admin';
  end if;
  if exists(
    select 1 from journey_communications_security_fixture f
    where f.owner_a_id=f.owner_b_id
      or f.owner_a_id in(f.captain_user_id,f.other_captain_user_id,f.operator_user_id,f.site_admin_user_id)
      or f.owner_b_id in(f.captain_user_id,f.other_captain_user_id,f.operator_user_id,f.site_admin_user_id)
      or f.captain_user_id in(f.other_captain_user_id,f.operator_user_id,f.site_admin_user_id)
      or f.other_captain_user_id in(f.operator_user_id,f.site_admin_user_id)
      or f.operator_user_id=f.site_admin_user_id
  ) then raise exception 'security fixture identities overlap'; end if;
end $$;

update pace_v2.departures d
set scheduled_departure_ts=now()+interval '24 hours',scheduled_arrival_ts=now()+interval '26 hours',actual_arrival_ts=null
from journey_communications_security_fixture f where d.id=f.departure_id;

-- Remove only Task 8 feedback for the two selected bookings; the transaction rollback
-- restores all seed rows after the matrix has run.
delete from pace_v2.platform_quality_history where booking_id in(select booking_a_id from journey_communications_security_fixture union all select booking_b_id from journey_communications_security_fixture);
delete from pace_v2.captain_quality_history where booking_id in(select booking_a_id from journey_communications_security_fixture union all select booking_b_id from journey_communications_security_fixture);
delete from pace_v2.pickup_quality_history where booking_id in(select booking_a_id from journey_communications_security_fixture union all select booking_b_id from journey_communications_security_fixture);
delete from pace_v2.destination_quality_history where booking_id in(select booking_a_id from journey_communications_security_fixture union all select booking_b_id from journey_communications_security_fixture);
delete from pace_v2.quality_evidence where booking_id in(select booking_a_id from journey_communications_security_fixture union all select booking_b_id from journey_communications_security_fixture);
delete from pace_v2.operational_alerts where booking_id in(select booking_a_id from journey_communications_security_fixture union all select booking_b_id from journey_communications_security_fixture) and exception_type in('journey_feedback_attribution_review','feedback_timezone_invalid');
delete from pace_v2.customer_feedback where booking_id in(select booking_a_id from journey_communications_security_fixture union all select booking_b_id from journey_communications_security_fixture);

select set_config('request.jwt.claim.sub',(select owner_a_id::text from journey_communications_security_fixture),true);
set local role authenticated;
update journey_communications_security_fixture
set conversation_a_id=public.v2_customer_open_captain_conversation(booking_a_id,'Task 8 customer A private message');
reset role;
select set_config('request.jwt.claim.sub',(select owner_b_id::text from journey_communications_security_fixture),true);
set local role authenticated;
update journey_communications_security_fixture
set conversation_b_id=public.v2_customer_open_captain_conversation(booking_b_id,'Task 8 customer B private message');
reset role;

-- Create one real captain broadcast before evaluating every role's projection.
select set_config('request.jwt.claim.sub',(select captain_user_id::text from journey_communications_security_fixture),true);
set local role authenticated;
update journey_communications_security_fixture
set broadcast_source_id=public.v2_captain_broadcast_to_parties(
  allocation_id,'Task 8 role-matrix broadcast','operational',broadcast_request_id
);
reset role;

-- Customer A: exactly its booking/thread, never B's data or write boundary.
select set_config('request.jwt.claim.sub',(select owner_a_id::text from journey_communications_security_fixture),true);
set local role authenticated;
do $$ declare v_count integer; v_error text; begin
  select count(distinct booking_id) into v_count from public.v2_customer_my_orders
  where booking_id in(select booking_a_id from journey_communications_security_fixture union all select booking_b_id from journey_communications_security_fixture);
  if v_count<>1 then raise exception 'customer A booking isolation failed: %',v_count; end if;
  select count(*) into v_count from public.v2_customer_my_journey_conversations
  where id in(select conversation_a_id from journey_communications_security_fixture union all select conversation_b_id from journey_communications_security_fixture);
  if v_count<>1 then raise exception 'customer A conversation isolation failed: %',v_count; end if;
  select count(distinct conversation_id) into v_count from public.v2_customer_my_journey_messages
  where conversation_id in(select conversation_a_id from journey_communications_security_fixture union all select conversation_b_id from journey_communications_security_fixture);
  if v_count<>1 then raise exception 'customer A message isolation failed: %',v_count; end if;
  select count(*) into v_count
  from public.v2_customer_my_journey_messages m join journey_communications_security_fixture f on m.broadcast_source_id=f.broadcast_source_id;
  if v_count<>1 then raise exception 'customer A private broadcast copy count failed: %',v_count; end if;
  if exists(
    select 1 from public.v2_customer_my_journey_messages m join journey_communications_security_fixture f on m.id=f.broadcast_source_id
  ) then raise exception 'customer A could read the captain broadcast source'; end if;
  begin perform public.v2_customer_send_captain_message((select conversation_b_id from journey_communications_security_fixture),'cross-party denial'); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'journey conversation not found' then raise exception 'customer A could write customer B thread: %',v_error; end if;
end $$;
reset role;

-- Customer B receives the same ownership boundary independently.
select set_config('request.jwt.claim.sub',(select owner_b_id::text from journey_communications_security_fixture),true);
set local role authenticated;
do $$ declare v_count integer; begin
  select count(distinct booking_id) into v_count from public.v2_customer_my_orders
  where booking_id in(select booking_a_id from journey_communications_security_fixture union all select booking_b_id from journey_communications_security_fixture);
  if v_count<>1 then raise exception 'customer B booking isolation failed: %',v_count; end if;
  select count(*) into v_count from public.v2_customer_my_journey_conversations
  where id in(select conversation_a_id from journey_communications_security_fixture union all select conversation_b_id from journey_communications_security_fixture);
  if v_count<>1 then raise exception 'customer B conversation isolation failed: %',v_count; end if;
  select count(distinct conversation_id) into v_count from public.v2_customer_my_journey_messages
  where conversation_id in(select conversation_a_id from journey_communications_security_fixture union all select conversation_b_id from journey_communications_security_fixture);
  if v_count<>1 then raise exception 'customer B message isolation failed: %',v_count; end if;
  select count(*) into v_count
  from public.v2_customer_my_journey_messages m join journey_communications_security_fixture f on m.broadcast_source_id=f.broadcast_source_id;
  if v_count<>1 then raise exception 'customer B private broadcast copy count failed: %',v_count; end if;
  if exists(
    select 1 from public.v2_customer_my_journey_messages m join journey_communications_security_fixture f on m.id=f.broadcast_source_id
  ) then raise exception 'customer B could read the captain broadcast source'; end if;
end $$;
reset role;

-- Assigned captain sees the allocation as two distinct party threads and can reply.
select set_config('request.jwt.claim.sub',(select captain_user_id::text from journey_communications_security_fixture),true);
set local role authenticated;
do $$ declare v_count integer; begin
  select count(*) into v_count from public.v2_captain_my_journey_conversations
  where id in(select conversation_a_id from journey_communications_security_fixture union all select conversation_b_id from journey_communications_security_fixture);
  if v_count<>2 then raise exception 'assigned captain did not receive two private threads: %',v_count; end if;
  select count(distinct conversation_id) into v_count from public.v2_captain_my_journey_messages
  where conversation_id in(select conversation_a_id from journey_communications_security_fixture union all select conversation_b_id from journey_communications_security_fixture);
  if v_count<>2 then raise exception 'assigned captain message visibility failed: %',v_count; end if;
  select count(*) into v_count
  from public.v2_captain_my_journey_messages m join journey_communications_security_fixture f
    on m.id=f.broadcast_source_id or m.broadcast_source_id=f.broadcast_source_id;
  if v_count<>3 then raise exception 'assigned captain did not see one source and two private broadcast copies: %',v_count; end if;
  perform public.v2_captain_reply_to_party((select conversation_a_id from journey_communications_security_fixture),'Assigned captain reply','operational');
end $$;
reset role;

-- Other captain and operator-only user have neither reads nor write capability.
select set_config('request.jwt.claim.sub',(select other_captain_user_id::text from journey_communications_security_fixture),true);
set local role authenticated;
do $$ declare v_count integer; v_error text; begin
  select count(*) into v_count from public.v2_captain_my_journey_conversations
  where id in(select conversation_a_id from journey_communications_security_fixture union all select conversation_b_id from journey_communications_security_fixture);
  if v_count<>0 then raise exception 'other captain read private threads: %',v_count; end if;
  select count(*) into v_count
  from public.v2_captain_my_journey_messages m join journey_communications_security_fixture f
    on m.id=f.broadcast_source_id or m.broadcast_source_id=f.broadcast_source_id;
  if v_count<>0 then raise exception 'other captain read broadcast source or private copies: %',v_count; end if;
  begin perform public.v2_captain_reply_to_party((select conversation_a_id from journey_communications_security_fixture),'other captain denial','operational'); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'journey conversation not assigned to captain' then raise exception 'other captain write denial mismatch: %',v_error; end if;
end $$;
reset role;

select set_config('request.jwt.claim.sub',(select operator_user_id::text from journey_communications_security_fixture),true);
set local role authenticated;
do $$ declare v_count integer; v_error text; begin
  select count(*) into v_count from public.v2_captain_my_journey_conversations
  where id in(select conversation_a_id from journey_communications_security_fixture union all select conversation_b_id from journey_communications_security_fixture);
  if v_count<>0 then raise exception 'operator-only user read private threads: %',v_count; end if;
  select count(*) into v_count
  from public.v2_captain_my_journey_messages m join journey_communications_security_fixture f
    on m.id=f.broadcast_source_id or m.broadcast_source_id=f.broadcast_source_id;
  if v_count<>0 then raise exception 'operator-only user read broadcast source or private copies: %',v_count; end if;
  begin perform public.v2_captain_reply_to_party((select conversation_a_id from journey_communications_security_fixture),'operator denial','operational'); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'journey conversation not assigned to captain' then raise exception 'operator-only write denial mismatch: %',v_error; end if;
end $$;
reset role;

-- Site Admin uses supervised projections and the intervention RPC.
select set_config('request.jwt.claim.sub',(select site_admin_user_id::text from journey_communications_security_fixture),true);
set local role authenticated;
do $$ declare v_count integer; begin
  select count(*) into v_count from public.v2_admin_journey_conversations
  where conversation_id in(select conversation_a_id from journey_communications_security_fixture union all select conversation_b_id from journey_communications_security_fixture);
  if v_count<>2 then raise exception 'Site Admin supervision hid a party thread: %',v_count; end if;
  select count(*) into v_count
  from public.v2_admin_journey_messages m join journey_communications_security_fixture f
    on m.id=f.broadcast_source_id or m.broadcast_source_id=f.broadcast_source_id;
  if v_count<>3 then raise exception 'Site Admin did not see one source and two private broadcast copies: %',v_count; end if;
  select count(*) into v_count
  from public.v2_admin_journey_broadcast_deliveries d join journey_communications_security_fixture f on d.broadcast_message_id=f.broadcast_source_id;
  if v_count<>2 then raise exception 'Site Admin did not see both broadcast deliveries: %',v_count; end if;
  perform public.v2_site_admin_reply_journey_conversation((select conversation_b_id from journey_communications_security_fixture),'Site Admin supervised intervention','operational');
end $$;
reset role;

-- Feedback attribution is derived only after completion; each customer sees only its
-- own response and cannot submit against the other booking.
update pace_v2.departures d set actual_arrival_ts=now()-interval '1 hour'
from journey_communications_security_fixture f where d.id=f.departure_id;

select set_config('request.jwt.claim.sub',(select owner_a_id::text from journey_communications_security_fixture),true);
set local role authenticated;
do $$ declare v_count integer; v_error text; begin
  update journey_communications_security_fixture
  set feedback_a_id=public.v2_customer_submit_feedback(booking_a_id,2,2,2,1,2,2,'Customer A evidence','Customer A improvement',false);
  begin perform public.v2_customer_submit_feedback((select booking_b_id from journey_communications_security_fixture),5,9,5,4,5,5,'cross-owner','cross-owner',false); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'eligible paid booking owned by the authenticated customer required' then raise exception 'customer A could submit feedback for B: %',v_error; end if;
  select count(distinct booking_id) into v_count from public.v2_customer_my_feedback
  where booking_id in(select booking_a_id from journey_communications_security_fixture union all select booking_b_id from journey_communications_security_fixture);
  if v_count<>1 then raise exception 'customer A feedback isolation failed: %',v_count; end if;
  select count(*) into v_count
  from public.v2_admin_journey_messages m join journey_communications_security_fixture f
    on m.id=f.broadcast_source_id or m.broadcast_source_id=f.broadcast_source_id;
  if v_count<>0 then raise exception 'customer A read Site Admin journey messages: %',v_count; end if;
  select count(*) into v_count
  from public.v2_admin_journey_broadcast_deliveries d join journey_communications_security_fixture f on d.broadcast_message_id=f.broadcast_source_id;
  if v_count<>0 then raise exception 'customer A read Site Admin broadcast deliveries: %',v_count; end if;
  select count(*) into v_count
  from public.v2_admin_operational_alerts a join journey_communications_security_fixture f on a.booking_id=f.booking_a_id
  where a.exception_type='journey_feedback_attribution_review';
  if v_count<>0 then raise exception 'customer A read Site Admin operational alerts: %',v_count; end if;
  v_error:=null;
  begin perform public.v2_site_admin_quality_dashboard(); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'site admin required' then raise exception 'customer A quality dashboard denial mismatch: %',v_error; end if;
  v_error:=null;
  begin perform public.v2_site_admin_quality_evidence_page(0,100); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'site admin required' then raise exception 'customer A quality evidence denial mismatch: %',v_error; end if;
end $$;
reset role;

select set_config('request.jwt.claim.sub',(select owner_b_id::text from journey_communications_security_fixture),true);
set local role authenticated;
do $$ declare v_count integer; v_error text; begin
  update journey_communications_security_fixture
  set feedback_b_id=public.v2_customer_submit_feedback(booking_b_id,4,8,4,5,4,4,'Customer B evidence','Customer B improvement',false);
  select count(distinct booking_id) into v_count from public.v2_customer_my_feedback
  where booking_id in(select booking_a_id from journey_communications_security_fixture union all select booking_b_id from journey_communications_security_fixture);
  if v_count<>1 then raise exception 'customer B feedback isolation failed: %',v_count; end if;
  select count(*) into v_count
  from public.v2_admin_journey_messages m join journey_communications_security_fixture f
    on m.id=f.broadcast_source_id or m.broadcast_source_id=f.broadcast_source_id;
  if v_count<>0 then raise exception 'customer B read Site Admin journey messages: %',v_count; end if;
  select count(*) into v_count
  from public.v2_admin_journey_broadcast_deliveries d join journey_communications_security_fixture f on d.broadcast_message_id=f.broadcast_source_id;
  if v_count<>0 then raise exception 'customer B read Site Admin broadcast deliveries: %',v_count; end if;
  select count(*) into v_count
  from public.v2_admin_operational_alerts a join journey_communications_security_fixture f on a.booking_id=f.booking_a_id
  where a.exception_type='journey_feedback_attribution_review';
  if v_count<>0 then raise exception 'customer B read Site Admin operational alerts: %',v_count; end if;
  begin perform public.v2_site_admin_quality_dashboard(); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'site admin required' then raise exception 'customer B quality dashboard denial mismatch: %',v_error; end if;
  v_error:=null;
  begin perform public.v2_site_admin_quality_evidence_page(0,100); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'site admin required' then raise exception 'customer B quality evidence denial mismatch: %',v_error; end if;
end $$;
reset role;

-- Captain, other-captain and operator-only claims cannot cross into owner feedback
-- or Site Admin messages, deliveries, alerts and quality reporting.
set local role authenticated;
do $$
declare
  v_identity uuid;
  v_label text;
  v_count integer;
  v_error text;
begin
  for v_identity,v_label in
    select captain_user_id,'assigned captain' from journey_communications_security_fixture
    union all select other_captain_user_id,'other captain' from journey_communications_security_fixture
    union all select operator_user_id,'operator-only user' from journey_communications_security_fixture
  loop
    perform set_config('request.jwt.claim.sub',v_identity::text,true);
    select count(*) into v_count from public.v2_customer_my_feedback f
    where f.booking_id in(select booking_a_id from journey_communications_security_fixture union all select booking_b_id from journey_communications_security_fixture);
    if v_count<>0 then raise exception '% read owner feedback: %',v_label,v_count; end if;
    select count(*) into v_count
    from public.v2_admin_journey_messages m join journey_communications_security_fixture f
      on m.id=f.broadcast_source_id or m.broadcast_source_id=f.broadcast_source_id;
    if v_count<>0 then raise exception '% read Site Admin journey messages: %',v_label,v_count; end if;
    select count(*) into v_count
    from public.v2_admin_journey_broadcast_deliveries d join journey_communications_security_fixture f on d.broadcast_message_id=f.broadcast_source_id;
    if v_count<>0 then raise exception '% read Site Admin broadcast deliveries: %',v_label,v_count; end if;
    select count(*) into v_count
    from public.v2_admin_operational_alerts a join journey_communications_security_fixture f on a.booking_id=f.booking_a_id
    where a.exception_type='journey_feedback_attribution_review';
    if v_count<>0 then raise exception '% read Site Admin operational alerts: %',v_label,v_count; end if;
    v_error:=null;
    begin perform public.v2_site_admin_quality_dashboard(); exception when others then v_error:=sqlerrm; end;
    if v_error is distinct from 'site admin required' then raise exception '% quality dashboard denial mismatch: %',v_label,v_error; end if;
    v_error:=null;
    begin perform public.v2_site_admin_quality_evidence_page(0,100); exception when others then v_error:=sqlerrm; end;
    if v_error is distinct from 'site admin required' then raise exception '% quality evidence denial mismatch: %',v_label,v_error; end if;
  end loop;
end $$;
reset role;

-- Site Admin sees both private conversations, all broadcast artifacts, the low-score
-- operational alert, aggregate dashboard response, and both owner evidence rows.
select set_config('request.jwt.claim.sub',(select site_admin_user_id::text from journey_communications_security_fixture),true);
set local role authenticated;
do $$
declare
  v_count integer;
  v_dashboard jsonb;
  v_page jsonb;
begin
  select count(*) into v_count from public.v2_admin_journey_conversations c
  where c.conversation_id in(select conversation_a_id from journey_communications_security_fixture union all select conversation_b_id from journey_communications_security_fixture);
  if v_count<>2 then raise exception 'Site Admin post-feedback conversation count failed: %',v_count; end if;
  select count(*) into v_count
  from public.v2_admin_journey_messages m join journey_communications_security_fixture f
    on m.id=f.broadcast_source_id or m.broadcast_source_id=f.broadcast_source_id;
  if v_count<>3 then raise exception 'Site Admin post-feedback broadcast messages failed: %',v_count; end if;
  select count(*) into v_count
  from public.v2_admin_journey_broadcast_deliveries d join journey_communications_security_fixture f on d.broadcast_message_id=f.broadcast_source_id;
  if v_count<>2 then raise exception 'Site Admin post-feedback deliveries failed: %',v_count; end if;
  select count(*) into v_count
  from public.v2_admin_operational_alerts a join journey_communications_security_fixture f on a.booking_id=f.booking_a_id
  where a.exception_type='journey_feedback_attribution_review' and a.details->>'feedback_id'=f.feedback_a_id::text;
  if v_count<>1 then raise exception 'Site Admin low-score alert visibility failed: %',v_count; end if;
  v_dashboard:=public.v2_site_admin_quality_dashboard();
  if coalesce((v_dashboard#>>'{platform,response_count}')::integer,0)<2 then
    raise exception 'Site Admin quality dashboard omitted Task 8 feedback: %',v_dashboard#>>'{platform,response_count}';
  end if;
  v_page:=public.v2_site_admin_quality_evidence_page(0,100);
  select count(*) into v_count
  from jsonb_array_elements(v_page->'items') item join journey_communications_security_fixture f
    on item->>'id' in(f.feedback_a_id::text,f.feedback_b_id::text);
  if v_count<>2 then raise exception 'Site Admin quality evidence page omitted Task 8 feedback rows: %',v_count; end if;
end $$;
reset role;

-- Anonymous role: actual protected view/table/RPC calls all fail with insufficient privilege.
select set_config('request.jwt.claim.sub','',true);
set local role anon;
do $$ declare v_state text; begin
  begin perform 1 from pace_v2.journey_conversations; exception when others then v_state:=sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'anonymous base conversation read was not denied: %',v_state; end if;
  v_state:=null;
  begin perform 1 from public.v2_customer_my_journey_conversations; exception when others then v_state:=sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'anonymous protected-view read was not denied: %',v_state; end if;
  v_state:=null;
  begin perform public.v2_customer_open_captain_conversation((select booking_a_id from journey_communications_security_fixture),'anonymous denial'); exception when others then v_state:=sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'anonymous messaging RPC was not denied: %',v_state; end if;
  v_state:=null;
  begin perform public.v2_customer_submit_feedback((select booking_a_id from journey_communications_security_fixture),5,9,5,5,5,5,'anonymous','anonymous',false); exception when others then v_state:=sqlstate; end;
  if v_state is distinct from '42501' then raise exception 'anonymous feedback RPC was not denied: %',v_state; end if;
end $$;
reset role;

-- Service execution: scheduling/claim/mark functions are callable only under the
-- server-held role. Zero-work/fake-id calls prove the grants without delivery.
select set_config('request.jwt.claim.sub','',true);
set local role service_role;
do $$ declare v_count integer; v_error text; begin
  perform public.v2_system_schedule_t24_journey_notifications('1900-01-01 00:00:00+00');
  perform public.v2_system_schedule_feedback_requests('1900-01-01 00:00:00+00',0);
  select count(*) into v_count from public.v2_system_claim_due_customer_emails_with_metadata(0);
  if v_count<>0 then raise exception 'zero-limit service claim returned rows'; end if;
  begin perform public.v2_system_mark_journey_broadcast_email_sent(gen_random_uuid(),gen_random_uuid(),'task-8-no-delivery'); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'broadcast notification and delivery do not match' then raise exception 'service sent-marker gate mismatch: %',v_error; end if;
  v_error:=null;
  begin perform public.v2_system_mark_journey_broadcast_email_failed(gen_random_uuid(),gen_random_uuid(),'task-8-no-delivery'); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'broadcast notification and delivery do not match' then raise exception 'service failed-marker gate mismatch: %',v_error; end if;
end $$;
reset role;

rollback;
