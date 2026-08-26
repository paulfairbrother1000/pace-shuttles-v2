begin;

do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema='pace_v2' and table_name='vehicle_route_offers'
      and column_name='below_minimum_operation_mode' and is_nullable='NO'
  ) then raise exception 'Route Offers require a non-null below-minimum mode'; end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema='pace_v2' and table_name='vehicle_considerations'
      and column_name='below_minimum_operation_mode' and is_nullable='NO'
  ) then raise exception 'considerations must snapshot below-minimum mode'; end if;

  if not exists (
    select 1 from information_schema.triggers
    where trigger_schema='pace_v2' and event_object_table='vehicle_considerations'
      and trigger_name='trg_00_sync_consideration_below_minimum_mode'
  ) then raise exception 'considerations require a mode snapshot trigger'; end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='pace_v2' and p.proname='protect_allocated_consideration_snapshot'
      and pg_get_functiondef(p.oid) ilike '%below_minimum_operation_mode%'
  ) then raise exception 'allocated snapshot protection must include below-minimum mode'; end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='v2_operator_save_vehicle'
      and pg_get_function_identity_arguments(p.oid)='p_vehicle jsonb'
  ) then raise exception 'operator aggregate save RPC is missing'; end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='v2_operator_save_vehicle'
      and pg_get_functiondef(p.oid) ilike '%pace_v2.is_site_admin()%'
      and pg_get_functiondef(p.oid) ilike '%v_requested_operator_id%'
      and pg_get_functiondef(p.oid) ilike '%vehicle does not belong to selected operator%'
  ) then raise exception 'Site Admin must be able to save for the explicitly selected operator'; end if;

  if exists (
    select 1 from information_schema.routine_privileges
    where specific_schema='public' and routine_name='v2_operator_save_vehicle'
      and grantee in ('PUBLIC','anon') and privilege_type='EXECUTE'
  ) then raise exception 'aggregate save RPC must not be executable by public/anon'; end if;

  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname in (
        'v2_operator_load_vehicle_editor','v2_operator_load_vehicle_editor_captains',
        'v2_operator_load_vehicle_editor_types','v2_operator_load_vehicle_editor_routes',
        'v2_operator_load_vehicle_editor_offers'
      )) <> 5 then raise exception 'operator vehicle editor read RPCs are incomplete'; end if;
end
$$;

rollback;
