begin;

drop function if exists public.v2_current_access_context();

create function public.v2_current_access_context()
returns table(
  user_id uuid,
  platform_role text,
  is_site_admin boolean,
  operator_ids uuid[],
  operator_roles text[],
  captain_ids uuid[],
  operator_memberships jsonb
)
language sql
stable
security definer
set search_path to 'public', 'pace_v2', 'auth'
as $function$
  select
    auth.uid(),
    coalesce(p.platform_role::text, 'customer'),
    coalesce(p.platform_role::text = 'site_admin', false),
    coalesce((
      select array_agg(distinct om.operator_id)
      from pace_v2.operator_memberships om
      where om.user_id = auth.uid() and om.active
    ), array[]::uuid[]),
    coalesce((
      select array_agg(distinct om.role::text)
      from pace_v2.operator_memberships om
      where om.user_id = auth.uid() and om.active
    ), array[]::text[]),
    coalesce((
      select array_agg(distinct c.id)
      from pace_v2.captains c
      where c.auth_user_id = auth.uid() and c.active
    ), array[]::uuid[]),
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'operator_id', om.operator_id,
          'operator_name', o.name,
          'role', om.role::text
        )
        order by o.name, om.role::text
      )
      from pace_v2.operator_memberships om
      join pace_v2.operators o on o.id = om.operator_id
      where om.user_id = auth.uid() and om.active
    ), '[]'::jsonb)
  from (select 1) x
  left join pace_v2.profiles p on p.user_id = auth.uid();
$function$;

revoke all on function public.v2_current_access_context() from public, anon;
grant execute on function public.v2_current_access_context() to authenticated;

commit;
