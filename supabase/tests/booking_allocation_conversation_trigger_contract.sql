do $$
declare
  v_security_definer boolean;
  v_config text[];
begin
  select p.prosecdef, p.proconfig
  into v_security_definer, v_config
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'pace_v2'
    and p.proname = 'validate_booking_allocation_conversation_change';

  if v_security_definer is distinct from true then
    raise exception 'booking allocation conversation trigger must run as its private-schema owner';
  end if;

  if not coalesce(v_config @> array['search_path=""'], false) then
    raise exception 'booking allocation conversation trigger must use an empty search_path';
  end if;

  if has_function_privilege('public', 'pace_v2.validate_booking_allocation_conversation_change()', 'execute')
     or has_function_privilege('anon', 'pace_v2.validate_booking_allocation_conversation_change()', 'execute')
     or has_function_privilege('authenticated', 'pace_v2.validate_booking_allocation_conversation_change()', 'execute')
     or has_function_privilege('service_role', 'pace_v2.validate_booking_allocation_conversation_change()', 'execute') then
    raise exception 'booking allocation conversation trigger must not be directly executable by API roles';
  end if;
end
$$;
