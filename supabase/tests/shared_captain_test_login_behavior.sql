begin;

do $$
declare
  v_shared_user_id uuid;
  v_ordinary_user_id uuid:=gen_random_uuid();
  v_admin_user_id uuid:=gen_random_uuid();
  v_operator_one uuid;
  v_operator_two uuid;
  v_shared_captain_one uuid;
  v_shared_captain_two uuid;
  v_ordinary_captain_one uuid;
  v_ordinary_captain_two uuid;
  v_captain_ids uuid[];
begin
  select id into v_shared_user_id
  from auth.users
  where lower(email)='psfairbrother@hotmail.com'
  limit 1;

  if v_shared_user_id is null then
    v_shared_user_id:=gen_random_uuid();
    insert into auth.users(id,email)
    values(v_shared_user_id,'psfairbrother@hotmail.com');
  end if;

  insert into auth.users(id,email)
  values
    (v_ordinary_user_id,'ordinary-shared-captain@example.test'),
    (v_admin_user_id,'shared-captain-admin@example.test');
  insert into pace_v2.profiles(user_id,platform_role)
  values(v_admin_user_id,'site_admin')
  on conflict(user_id) do update set platform_role='site_admin';

  insert into pace_v2.operators(id,name,active)
  values(gen_random_uuid(),'Shared captain operator one '||gen_random_uuid(),true)
  returning id into v_operator_one;
  insert into pace_v2.operators(id,name,active)
  values(gen_random_uuid(),'Shared captain operator two '||gen_random_uuid(),true)
  returning id into v_operator_two;

  insert into pace_v2.captains(operator_id,first_name,last_name,email,active)
  values
    (v_operator_one,'Shared','Captain One','shared-one-'||gen_random_uuid()||'@example.test',true)
  returning id into v_shared_captain_one;
  insert into pace_v2.captains(operator_id,first_name,last_name,email,active)
  values
    (v_operator_two,'Shared','Captain Two','shared-two-'||gen_random_uuid()||'@example.test',true)
  returning id into v_shared_captain_two;
  insert into pace_v2.captains(operator_id,first_name,last_name,email,active)
  values
    (v_operator_one,'Ordinary','Captain One','ordinary-one-'||gen_random_uuid()||'@example.test',true)
  returning id into v_ordinary_captain_one;
  insert into pace_v2.captains(operator_id,first_name,last_name,email,active)
  values
    (v_operator_two,'Ordinary','Captain Two','ordinary-two-'||gen_random_uuid()||'@example.test',true)
  returning id into v_ordinary_captain_two;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub',v_admin_user_id::text,true);
  perform public.v2_admin_link_captain_user(v_shared_captain_one,'psfairbrother@hotmail.com');
  perform public.v2_admin_link_captain_user(v_shared_captain_two,'psfairbrother@hotmail.com');
  reset role;

  if (select count(*) from pace_v2.captains where auth_user_id=v_shared_user_id)<2 then
    raise exception 'approved shared captain login did not link twice';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub',v_shared_user_id::text,true);
  select captain_ids into v_captain_ids from public.v2_current_access_context();
  reset role;
  if not (v_shared_captain_one=any(v_captain_ids) and v_shared_captain_two=any(v_captain_ids)) then
    raise exception 'shared sign-in did not resolve both captain identities';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claim.sub',v_admin_user_id::text,true);
  perform public.v2_admin_link_captain_user(v_ordinary_captain_one,'ordinary-shared-captain@example.test');
  begin
    perform public.v2_admin_link_captain_user(v_ordinary_captain_two,'ordinary-shared-captain@example.test');
    raise exception 'expected ordinary shared captain login rejection';
  exception
    when others then
      if sqlerrm not ilike '%captain login is already linked to another captain%' then
        raise;
      end if;
  end;
  reset role;
end $$;

rollback;
