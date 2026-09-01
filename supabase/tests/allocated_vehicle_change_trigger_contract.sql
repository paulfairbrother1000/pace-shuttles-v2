do $$
declare
  v_function regprocedure := 'pace_v2.validate_allocated_vehicle_change()'::regprocedure;
begin
  if not (select p.prosecdef from pg_proc p where p.oid=v_function) then
    raise exception 'allocated vehicle constraint trigger must run as a security definer';
  end if;

  if coalesce((select p.proconfig @> array['search_path=""'] from pg_proc p where p.oid=v_function),false) is not true then
    raise exception 'allocated vehicle constraint trigger must use an empty search path';
  end if;

  if has_function_privilege('public',v_function,'execute')
     or has_function_privilege('anon',v_function,'execute')
     or has_function_privilege('authenticated',v_function,'execute') then
    raise exception 'allocated vehicle constraint trigger must not be directly executable by API roles';
  end if;
end $$;
