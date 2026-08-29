begin;

do $$
declare
  v_non_read_grants integer;
begin
  select count(*)
    into v_non_read_grants
  from information_schema.role_table_grants
  where grantee in ('anon', 'authenticated')
    and table_schema = 'public'
    and table_name like 'v2\_%' escape '\'
    and privilege_type <> 'SELECT';

  if v_non_read_grants <> 0 then
    raise exception 'public V2 facade exposes % non-read grants to anon/authenticated',
      v_non_read_grants;
  end if;

  if exists (
    select 1
    from information_schema.role_table_grants
    where grantee = 'anon'
      and table_schema = 'public'
      and table_name like 'v2\_%' escape '\'
      and table_name not like 'v2\_public\_%' escape '\'
      and privilege_type = 'SELECT'
  ) then
    raise exception 'anonymous reads must be limited to v2_public_* views';
  end if;
end
$$;

select set_config(
  'request.jwt.claim.sub',
  (
    select p.user_id::text
    from pace_v2.profiles p
    where coalesce(p.platform_role, 'customer') <> 'site_admin'
      and not exists (
        select 1 from pace_v2.operator_memberships om
        where om.user_id = p.user_id and om.active
      )
      and not exists (
        select 1 from pace_v2.captains c
        where c.auth_user_id = p.user_id and c.active
      )
    order by p.user_id
    limit 1
  ),
  true
);

set local role authenticated;

do $$
declare
  v_view record;
  v_rows bigint;
begin
  if auth.uid() is null then
    raise exception 'fixture: a plain customer profile is required';
  end if;

  for v_view in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'v'
      and (
        c.relname like 'v2\_admin\_%' escape '\'
        or c.relname like 'v2\_api\_admin\_%' escape '\'
      )
      and has_table_privilege(
        current_user,
        format('public.%I', c.relname),
        'select'
      )
  loop
    execute format('select count(*) from public.%I', v_view.relname)
      into v_rows;
    if v_rows <> 0 then
      raise exception 'customer can read % rows from privileged view %',
        v_rows,
        v_view.relname;
    end if;
  end loop;
end
$$;

reset role;

rollback;
