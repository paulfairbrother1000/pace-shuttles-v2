alter table pace_v2.captains
  add column if not exists operator_vetting_confirmed boolean not null default false,
  add column if not exists operator_vetting_confirmed_at timestamptz,
  add column if not exists operator_vetting_recorded_by uuid references auth.users(id) on delete set null;

create or replace function public.v2_admin_save_captain(
  p_captain_id uuid,
  p_operator_id uuid,
  p_first_name text,
  p_last_name text,
  p_email text default null,
  p_phone text default null,
  p_notes text default null,
  p_active boolean default true,
  p_operator_vetting_confirmed boolean default false,
  p_vehicle_type_ids uuid[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path to 'public','pace_v2','auth'
as $function$
declare
  v_captain_id uuid;
  v_type_id uuid;
  v_link_id uuid;
begin
  if not pace_v2.is_site_admin() then
    raise exception 'site admin required';
  end if;
  if nullif(trim(coalesce(p_first_name,'')),'') is null
     or nullif(trim(coalesce(p_last_name,'')),'') is null then
    raise exception 'captain first and last name required';
  end if;
  if not exists(select 1 from pace_v2.operators where id=p_operator_id) then
    raise exception 'operator not found';
  end if;
  if coalesce(p_active,true) and coalesce(cardinality(p_vehicle_type_ids),0)=0 then
    raise exception 'select at least one transport type for an active captain';
  end if;
  if coalesce(p_active,true) and not coalesce(p_operator_vetting_confirmed,false) then
    raise exception 'operator vetting and licence confirmation is required for an active captain';
  end if;
  if exists(
    select 1
    from unnest(coalesce(p_vehicle_type_ids,'{}'::uuid[])) selected(vehicle_type_id)
    left join pace_v2.vehicle_types vehicle_type on vehicle_type.id=selected.vehicle_type_id
    where vehicle_type.id is null or not vehicle_type.active
  ) then
    raise exception 'selected transport type is unavailable';
  end if;

  if p_captain_id is null then
    insert into pace_v2.captains(
      operator_id,first_name,last_name,email,phone,notes,active,
      operator_vetting_confirmed,operator_vetting_confirmed_at,operator_vetting_recorded_by,updated_at
    ) values (
      p_operator_id,trim(p_first_name),trim(p_last_name),
      nullif(trim(coalesce(p_email,'')),''),nullif(trim(coalesce(p_phone,'')),''),
      nullif(trim(coalesce(p_notes,'')),''),coalesce(p_active,true),
      coalesce(p_operator_vetting_confirmed,false),
      case when coalesce(p_operator_vetting_confirmed,false) then now() else null end,
      case when coalesce(p_operator_vetting_confirmed,false) then auth.uid() else null end,
      now()
    ) returning id into v_captain_id;
  else
    update pace_v2.captains
    set first_name=trim(p_first_name),
        last_name=trim(p_last_name),
        email=nullif(trim(coalesce(p_email,'')),''),
        phone=nullif(trim(coalesce(p_phone,'')),''),
        notes=nullif(trim(coalesce(p_notes,'')),''),
        active=coalesce(p_active,true),
        operator_vetting_confirmed=coalesce(p_operator_vetting_confirmed,false),
        operator_vetting_confirmed_at=case when coalesce(p_operator_vetting_confirmed,false) then now() else null end,
        operator_vetting_recorded_by=case when coalesce(p_operator_vetting_confirmed,false) then auth.uid() else null end,
        updated_at=now()
    where id=p_captain_id and operator_id=p_operator_id
    returning id into v_captain_id;
    if v_captain_id is null then
      raise exception 'captain not found for operator';
    end if;
  end if;

  update pace_v2.captain_vehicle_types
  set active=false
  where captain_id=v_captain_id
    and not (vehicle_type_id=any(coalesce(p_vehicle_type_ids,'{}'::uuid[])));

  for v_type_id in
    select distinct selected.vehicle_type_id
    from unnest(coalesce(p_vehicle_type_ids,'{}'::uuid[])) selected(vehicle_type_id)
  loop
    select id into v_link_id
    from pace_v2.captain_vehicle_types
    where captain_id=v_captain_id and vehicle_type_id=v_type_id
    limit 1;
    if v_link_id is null then
      insert into pace_v2.captain_vehicle_types(captain_id,vehicle_type_id,active)
      values(v_captain_id,v_type_id,true);
    else
      update pace_v2.captain_vehicle_types set active=true where id=v_link_id;
    end if;
  end loop;

  return v_captain_id;
end
$function$;

revoke all on function public.v2_admin_save_captain(uuid,uuid,text,text,text,text,text,boolean,boolean,uuid[]) from public,anon;
grant execute on function public.v2_admin_save_captain(uuid,uuid,text,text,text,text,text,boolean,boolean,uuid[]) to authenticated;

create or replace view public.v2_captains as
select
  captain.id,
  captain.operator_id,
  captain.auth_user_id,
  captain.first_name,
  captain.last_name,
  captain.email,
  captain.phone,
  captain.photo_url,
  captain.notes,
  captain.active,
  captain.created_at,
  captain.updated_at,
  captain.operator_vetting_confirmed,
  captain.operator_vetting_confirmed_at,
  captain.operator_vetting_recorded_by,
  coalesce(
    array(
      select eligibility.vehicle_type_id
      from pace_v2.captain_vehicle_types eligibility
      where eligibility.captain_id=captain.id and eligibility.active
      order by eligibility.vehicle_type_id
    ),
    '{}'::uuid[]
  ) as vehicle_type_ids
from pace_v2.captains captain
where pace_v2.is_site_admin();
