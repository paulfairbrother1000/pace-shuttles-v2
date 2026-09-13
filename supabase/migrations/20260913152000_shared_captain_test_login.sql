drop index if exists pace_v2.ux_captains_auth_user;

create index if not exists ix_captains_auth_user
on pace_v2.captains(auth_user_id)
where auth_user_id is not null;

create or replace function pace_v2.guard_captain_shared_test_login()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_email text;
begin
  if new.auth_user_id is null then
    return new;
  end if;

  select lower(trim(u.email))
  into v_email
  from auth.users u
  where u.id=new.auth_user_id;

  if v_email is null then
    raise exception 'captain login user not found';
  end if;

  if v_email<>'psfairbrother@hotmail.com'
     and exists(
       select 1
       from pace_v2.captains c
       where c.auth_user_id=new.auth_user_id
         and c.id<>new.id
     ) then
    raise exception 'captain login is already linked to another captain';
  end if;

  return new;
end;
$$;

drop trigger if exists captains_guard_shared_test_login on pace_v2.captains;
create constraint trigger captains_guard_shared_test_login
after insert or update of auth_user_id on pace_v2.captains
deferrable initially immediate
for each row execute function pace_v2.guard_captain_shared_test_login();

create or replace function public.v2_admin_link_captain_user(
  p_captain_id uuid,
  p_email text
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_uid uuid;
  v_email text;
begin
  if not pace_v2.is_site_admin() then
    raise exception 'site admin required';
  end if;

  select u.id,lower(trim(u.email))
  into v_uid,v_email
  from auth.users u
  where lower(u.email)=lower(trim(p_email))
  limit 1;

  if v_uid is null then
    raise exception 'No signed-up user exists with that email. Ask the captain to sign in once first.';
  end if;

  if v_email<>'psfairbrother@hotmail.com'
     and exists(
       select 1
       from pace_v2.captains c
       where c.auth_user_id=v_uid
         and c.id<>p_captain_id
     ) then
    raise exception 'captain login is already linked to another captain';
  end if;

  update pace_v2.captains
  set auth_user_id=v_uid,updated_at=now()
  where id=p_captain_id;

  if not found then
    raise exception 'captain not found';
  end if;

  return v_uid;
end;
$$;

revoke all on function pace_v2.guard_captain_shared_test_login() from public,anon,authenticated;
revoke all on function public.v2_admin_link_captain_user(uuid,text) from public,anon,authenticated;
grant execute on function public.v2_admin_link_captain_user(uuid,text) to authenticated;

notify pgrst,'reload schema';
