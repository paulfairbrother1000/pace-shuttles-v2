create or replace function public.v2_captain_my_identities()
returns table(
  captain_id uuid,
  captain_name text,
  operator_id uuid,
  operator_name text
)
language sql
stable
security definer
set search_path=''
as $$
  select
    captain.id,
    trim(concat_ws(' ',captain.first_name,captain.last_name)),
    operator.id,
    operator.name
  from pace_v2.captains captain
  join pace_v2.operators operator on operator.id=captain.operator_id
  where (select auth.uid()) is not null
    and captain.auth_user_id=(select auth.uid())
    and captain.active
    and operator.active
  order by operator.name,captain.last_name,captain.first_name,captain.id
$$;

revoke all on function public.v2_captain_my_identities() from public,anon,authenticated;
grant execute on function public.v2_captain_my_identities() to authenticated;

notify pgrst,'reload schema';
