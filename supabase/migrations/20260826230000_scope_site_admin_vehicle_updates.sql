-- The selected operator is part of the write boundary for existing vehicles too.
-- This protects against stale or tampered Site Admin editor state.
do $$
declare
  v_definition text;
  v_existing_guard text := $guard$
    if v_operator_id is null then raise exception 'vehicle not found'; end if;
    if not pace_v2.has_operator_access(v_operator_id) then raise exception 'operator access required'; end if;
$guard$;
  v_scoped_guard text := $scoped$
    if v_operator_id is null then raise exception 'vehicle not found'; end if;
    if v_requested_operator_id is not null and v_operator_id<>v_requested_operator_id then raise exception 'vehicle does not belong to selected operator'; end if;
    if not pace_v2.has_operator_access(v_operator_id) then raise exception 'operator access required'; end if;
$scoped$;
begin
  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='v2_operator_save_vehicle'
    and pg_get_function_identity_arguments(p.oid)='p_vehicle jsonb';

  if v_definition is null then raise exception 'v2_operator_save_vehicle(jsonb) is missing'; end if;
  if strpos(v_definition,v_scoped_guard)>0 then return; end if;
  if strpos(v_definition,v_existing_guard)=0 then raise exception 'v2_operator_save_vehicle existing vehicle guard has changed'; end if;
  execute replace(v_definition,v_existing_guard,v_scoped_guard);
end
$$;
