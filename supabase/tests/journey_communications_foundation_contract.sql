begin;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'journey_conversations',
    'journey_conversation_messages',
    'journey_broadcast_deliveries',
    'operational_alerts'
  ] loop
    if not exists (
      select 1 from information_schema.tables
      where table_schema='pace_v2' and table_name=v_table
    ) then
      raise exception '% missing',v_table;
    end if;

    if not exists (
      select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='pace_v2' and c.relname=v_table and c.relrowsecurity
    ) then
      raise exception '% is not protected by RLS',v_table;
    end if;
  end loop;

  if not exists (
    select 1 from pg_constraint
    where conname='journey_conversations_booking_allocation_key'
  ) then
    raise exception 'one private thread per booking/allocation is not enforced';
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname='journey_broadcast_deliveries_broadcast_booking_key'
  ) then
    raise exception 'broadcast delivery de-duplication is not enforced';
  end if;

  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='pace_v2' and c.relname='operational_alerts_active_exception_key'
  ) then
    raise exception 'active operational exception de-duplication is not enforced';
  end if;

  if not exists (
    select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid
      join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='pace_v2' and c.relname='confirmed_allocations'
      and t.tgname='confirmed_allocations_require_eligible_captain'
      and t.tgdeferrable and t.tginitdeferred
  ) then
    raise exception 'confirmed allocations do not defer captain eligibility until commit';
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='pace_v2' and p.proname='journey_message_opens_at'
  ) or not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='pace_v2' and p.proname='journey_message_closes_at'
  ) or not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='pace_v2' and p.proname='is_journey_message_window_open'
  ) then
    raise exception 'message window helpers missing';
  end if;

  if has_function_privilege('anon','pace_v2.is_journey_message_window_open(uuid,timestamp with time zone)','execute') then
    raise exception 'message window helper is publicly executable';
  end if;
end $$;

do $$
declare
  v_table text;
  v_helper regprocedure;
begin
  foreach v_table in array array[
    'journey_conversations',
    'journey_conversation_messages',
    'journey_broadcast_deliveries',
    'operational_alerts'
  ] loop
    if not exists (
      select 1 from pg_constraint c
      where c.conrelid=('pace_v2.'||v_table)::regclass and c.contype='p'
    ) then raise exception '% primary key missing',v_table; end if;

    if has_table_privilege('anon','pace_v2.'||v_table,'select,insert,update,delete')
      or has_table_privilege('authenticated','pace_v2.'||v_table,'select,insert,update,delete') then
      raise exception '% has direct anonymous or authenticated table grants',v_table;
    end if;
  end loop;

  if not exists (
    select 1 from pg_constraint c
    where c.conrelid='pace_v2.journey_conversations'::regclass and c.contype='f'
      and c.confrelid='pace_v2.bookings'::regclass
  ) or not exists (
    select 1 from pg_constraint c
    where c.conrelid='pace_v2.journey_conversations'::regclass and c.contype='f'
      and c.confrelid='pace_v2.confirmed_allocations'::regclass
  ) then raise exception 'journey conversation foreign keys missing'; end if;

  if not exists (
    select 1 from pg_constraint c
    where c.conrelid='pace_v2.journey_conversation_messages'::regclass and c.contype='f'
      and c.confrelid='pace_v2.journey_conversations'::regclass
  ) or not exists (
    select 1 from pg_constraint c
    where c.conrelid='pace_v2.journey_broadcast_deliveries'::regclass and c.contype='f'
      and c.confrelid='pace_v2.journey_conversation_messages'::regclass
  ) then raise exception 'message or broadcast foreign keys missing'; end if;

  if not exists (
    select 1 from pg_trigger t
    where t.tgrelid='pace_v2.journey_conversation_messages'::regclass
      and t.tgname='journey_messages_are_immutable'
      and pg_get_triggerdef(t.oid) ilike '%before%update%'
      and pg_get_triggerdef(t.oid) ilike '%before%delete%'
  ) then raise exception 'journey messages are mutable'; end if;

  foreach v_table in array array[
    'confirmed_allocations_require_eligible_captain',
    'captain_assignments_preserve_eligible_allocation_captain',
    'captains_preserve_eligible_allocation_captain',
    'captain_vehicle_types_preserve_eligible_allocation_captain',
    'vehicles_preserve_eligible_allocation_captain'
  ] loop
    if not exists(select 1 from pg_trigger where tgname=v_table and tgdeferrable and tginitdeferred) then
      raise exception 'deferred invariant trigger % missing',v_table;
    end if;
  end loop;

  if not exists(select 1 from pg_trigger where tgname='journey_conversation_identity_is_immutable')
    or not exists(select 1 from pg_trigger where tgname='journey_broadcast_delivery_identity_is_valid')
    or not exists(select 1 from pg_trigger where tgname='booking_allocations_preserve_journey_conversation_identity') then
    raise exception 'journey identity triggers missing';
  end if;

  foreach v_helper in array array[
    'pace_v2.journey_message_opens_at(uuid)'::regprocedure,
    'pace_v2.journey_message_closes_at(uuid)'::regprocedure,
    'pace_v2.is_journey_message_window_open(uuid,timestamp with time zone)'::regprocedure
  ] loop
    if v_helper is null then raise exception 'message window helper signature missing'; end if;
    if exists (
      select 1 from pg_proc p where p.oid=v_helper
        and (p.proconfig is null or not p.proconfig @> array['search_path=pace_v2, public'])
    ) then raise exception 'message window helper % has unsafe search path',v_helper; end if;
    if has_function_privilege('anon',v_helper,'execute')
      or has_function_privilege('authenticated',v_helper,'execute') then
      raise exception 'message window helper % is directly executable',v_helper;
    end if;
  end loop;
end $$;

do $$
declare
  v_table regclass;
  v_missing text[]:=array[]::text[];
begin
  foreach v_table in array array[
    'pace_v2.journey_conversations'::regclass,
    'pace_v2.journey_conversation_messages'::regclass,
    'pace_v2.journey_broadcast_deliveries'::regclass,
    'pace_v2.operational_alerts'::regclass
  ] loop
    if exists(select 1 from pg_class c cross join lateral aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) acl where c.oid=v_table and acl.grantee=0) then
      raise exception '% retains PUBLIC table privilege',v_table;
    end if;
  end loop;

  if not exists(select 1 from pg_constraint where conrelid='pace_v2.journey_conversation_messages'::regclass and contype='f' and confrelid='auth.users'::regclass)
    or (select count(*) from pg_constraint where conrelid='pace_v2.journey_conversation_messages'::regclass and contype='f' and confrelid='pace_v2.journey_conversation_messages'::regclass)<>1
    or not exists(select 1 from pg_constraint where conrelid='pace_v2.journey_broadcast_deliveries'::regclass and contype='f' and confrelid='pace_v2.bookings'::regclass)
    or not exists(select 1 from pg_constraint where conrelid='pace_v2.journey_broadcast_deliveries'::regclass and contype='f' and confrelid='pace_v2.journey_conversations'::regclass)
    or not exists(select 1 from pg_constraint where conrelid='pace_v2.operational_alerts'::regclass and contype='f' and confrelid='pace_v2.confirmed_allocations'::regclass)
    or not exists(select 1 from pg_constraint where conrelid='pace_v2.operational_alerts'::regclass and contype='f' and confrelid='pace_v2.bookings'::regclass)
    or not exists(select 1 from pg_constraint where conrelid='pace_v2.operational_alerts'::regclass and contype='f' and confrelid='pace_v2.departures'::regclass)
    or not exists(select 1 from pg_constraint where conrelid='pace_v2.operational_alerts'::regclass and contype='f' and confrelid='auth.users'::regclass) then
    raise exception 'required message, delivery, or operational alert foreign keys missing';
  end if;

  if not exists(select 1 from information_schema.columns where table_schema='pace_v2' and table_name='departures' and column_name='actual_arrival_ts' and data_type='timestamp with time zone') then
    raise exception 'actual_arrival_ts completion field missing';
  end if;

  if pace_v2.is_journey_message_window_open(gen_random_uuid(),now()) is distinct from false then
    raise exception 'missing allocation message window must be false';
  end if;

  if exists(
    select 1 from pg_proc p cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) acl
    where p.oid in ('pace_v2.journey_message_opens_at(uuid)'::regprocedure,'pace_v2.journey_message_closes_at(uuid)'::regprocedure,'pace_v2.is_journey_message_window_open(uuid,timestamp with time zone)'::regprocedure)
      and acl.grantee=0 and acl.privilege_type='EXECUTE'
  ) then raise exception 'message window helper retains PUBLIC execution'; end if;
end $$;

rollback;
