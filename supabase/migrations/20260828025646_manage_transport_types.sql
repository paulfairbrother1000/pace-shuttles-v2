-- Site Admin transport-type catalogue and atomic operator/type assignment.

create or replace function public.v2_admin_save_vehicle_type(
 p_vehicle_type_id uuid,
 p_code text,
 p_name text,
 p_description text default null,
 p_picture_url text default null,
 p_display_order integer default 0,
 p_active boolean default true
) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 if trim(coalesce(p_code,''))='' then raise exception 'transport type code required'; end if;
 if trim(coalesce(p_name,''))='' then raise exception 'transport type name required'; end if;
 if exists(select 1 from pace_v2.vehicle_types where upper(code)=upper(trim(p_code)) and id is distinct from p_vehicle_type_id) then raise exception 'transport type code already exists'; end if;
 if coalesce(p_display_order,-1)<0 then raise exception 'display order must be zero or greater'; end if;
 if p_vehicle_type_id is not null and not coalesce(p_active,true) and exists(
  select 1 from pace_v2.operator_vehicle_types where vehicle_type_id=p_vehicle_type_id and status='approved'
 ) then raise exception 'transport type is still assigned to one or more operators'; end if;
 if p_vehicle_type_id is not null and not coalesce(p_active,true) and exists(
  select 1 from pace_v2.vehicles where vehicle_type_id=p_vehicle_type_id
 ) then raise exception 'transport type is still used by one or more vehicles'; end if;
 if p_vehicle_type_id is null then
  insert into pace_v2.vehicle_types(code,name,description,picture_url,display_order,active)
  values(upper(trim(p_code)),trim(p_name),nullif(trim(coalesce(p_description,'')),''),nullif(trim(coalesce(p_picture_url,'')),''),p_display_order,coalesce(p_active,true))
  returning id into v_id;
 else
  update pace_v2.vehicle_types set code=upper(trim(p_code)),name=trim(p_name),description=nullif(trim(coalesce(p_description,'')),''),picture_url=nullif(trim(coalesce(p_picture_url,'')),''),display_order=p_display_order,active=coalesce(p_active,true),updated_at=now()
  where id=p_vehicle_type_id returning id into v_id;
  if v_id is null then raise exception 'transport type not found'; end if;
 end if;
 return v_id;
end $$;

revoke all on function public.v2_admin_save_vehicle_type(uuid,text,text,text,text,integer,boolean) from public,anon;
grant execute on function public.v2_admin_save_vehicle_type(uuid,text,text,text,text,integer,boolean) to authenticated;

drop function if exists public.v2_admin_save_operator(uuid,text,uuid,text,text,text,text,text,text,text,uuid,uuid,text,text,text,text,boolean,boolean,uuid);
create function public.v2_admin_save_operator(
 p_operator_id uuid,
 p_name text,
 p_country_id uuid,
 p_admin_email text default null,
 p_email text default null,
 p_contact_email text default null,
 p_notification_email text default null,
 p_phone text default null,
 p_address1 text default null,
 p_address2 text default null,
 p_region_id uuid default null,
 p_locality_id uuid default null,
 p_town text default null,
 p_region_text text default null,
 p_postal_code text default null,
 p_logo_url text default null,
 p_white_label_member boolean default false,
 p_active boolean default true,
 p_cancellation_policy_id uuid default null,
 p_vehicle_type_ids uuid[] default '{}'::uuid[]
) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_type_id uuid;
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 if trim(coalesce(p_name,''))='' then raise exception 'operator name required'; end if;
 if trim(coalesce(p_admin_email,''))='' then raise exception 'operator admin email required'; end if;
 if p_country_id is null or not exists(select 1 from pace_v2.countries where id=p_country_id) then raise exception 'valid country required'; end if;
 if coalesce(cardinality(p_vehicle_type_ids),0)=0 then raise exception 'at least one transport type required'; end if;
 if exists(select 1 from unnest(p_vehicle_type_ids) x(id) left join pace_v2.vehicle_types vt on vt.id=x.id and vt.active where vt.id is null) then raise exception 'transport type not found or inactive'; end if;
 if p_region_id is not null and not exists(select 1 from pace_v2.regions where id=p_region_id and country_id=p_country_id) then raise exception 'region does not belong to operator country'; end if;
 if p_locality_id is not null and not exists(select 1 from pace_v2.localities where id=p_locality_id and country_id=p_country_id and (p_region_id is null or region_id=p_region_id)) then raise exception 'locality does not belong to operator geography'; end if;
 if p_cancellation_policy_id is not null and not exists(select 1 from pace_v2.cancellation_policies where id=p_cancellation_policy_id) then raise exception 'cancellation policy not found'; end if;
 if p_operator_id is null then
  insert into pace_v2.operators(name,country_id,admin_email,email,contact_email,notification_email,phone,address1,address2,region_id,locality_id,town,region,postal_code,logo_url,white_label_member,active,cancellation_policy_id)
  values(trim(p_name),p_country_id,lower(trim(p_admin_email)),nullif(lower(trim(coalesce(p_email,''))),''),nullif(lower(trim(coalesce(p_contact_email,''))),''),nullif(lower(trim(coalesce(p_notification_email,''))),''),nullif(trim(coalesce(p_phone,'')),''),nullif(trim(coalesce(p_address1,'')),''),nullif(trim(coalesce(p_address2,'')),''),p_region_id,p_locality_id,nullif(trim(coalesce(p_town,'')),''),nullif(trim(coalesce(p_region_text,'')),''),nullif(trim(coalesce(p_postal_code,'')),''),nullif(trim(coalesce(p_logo_url,'')),''),coalesce(p_white_label_member,false),coalesce(p_active,true),p_cancellation_policy_id)
  returning id into v_id;
 else
  update pace_v2.operators set name=trim(p_name),country_id=p_country_id,admin_email=lower(trim(p_admin_email)),email=nullif(lower(trim(coalesce(p_email,''))),''),contact_email=nullif(lower(trim(coalesce(p_contact_email,''))),''),notification_email=nullif(lower(trim(coalesce(p_notification_email,''))),''),phone=nullif(trim(coalesce(p_phone,'')),''),address1=nullif(trim(coalesce(p_address1,'')),''),address2=nullif(trim(coalesce(p_address2,'')),''),region_id=p_region_id,locality_id=p_locality_id,town=nullif(trim(coalesce(p_town,'')),''),region=nullif(trim(coalesce(p_region_text,'')),''),postal_code=nullif(trim(coalesce(p_postal_code,'')),''),logo_url=nullif(trim(coalesce(p_logo_url,'')),''),white_label_member=coalesce(p_white_label_member,false),active=coalesce(p_active,true),cancellation_policy_id=p_cancellation_policy_id,updated_at=now()
  where id=p_operator_id returning id into v_id;
  if v_id is null then raise exception 'operator not found'; end if;
 end if;

 if exists(
  select 1 from pace_v2.operator_vehicle_types ovt
  join pace_v2.vehicles v on v.operator_id=ovt.operator_id and v.vehicle_type_id=ovt.vehicle_type_id
  where ovt.operator_id=v_id and ovt.status='approved' and not (ovt.vehicle_type_id=any(p_vehicle_type_ids))
 ) then raise exception 'cannot remove transport type while the operator still has vehicles of that type'; end if;

 update pace_v2.operator_vehicle_types set status='suspended',suspended_at=now(),updated_at=now(),note='Removed in Site Admin operator form'
 where operator_id=v_id and status='approved' and not (vehicle_type_id=any(p_vehicle_type_ids));
 foreach v_type_id in array p_vehicle_type_ids loop
  insert into pace_v2.operator_vehicle_types(operator_id,vehicle_type_id,status,approved_at,approved_by,note)
  values(v_id,v_type_id,'approved',now(),auth.uid(),'Approved in Site Admin operator form')
  on conflict(operator_id,vehicle_type_id) do update set status='approved',approved_at=now(),approved_by=auth.uid(),suspended_at=null,updated_at=now(),note='Approved in Site Admin operator form';
 end loop;
 return v_id;
end $$;

revoke all on function public.v2_admin_save_operator(uuid,text,uuid,text,text,text,text,text,text,text,uuid,uuid,text,text,text,text,boolean,boolean,uuid,uuid[]) from public,anon;
grant execute on function public.v2_admin_save_operator(uuid,text,uuid,text,text,text,text,text,text,text,uuid,uuid,text,text,text,text,boolean,boolean,uuid,uuid[]) to authenticated;

drop policy if exists "Site Admin uploads transport type images" on storage.objects;
create policy "Site Admin uploads transport type images" on storage.objects for insert to authenticated
with check(bucket_id='images' and pace_v2.is_site_admin() and (storage.foldername(name))[1]='transport-types');
drop policy if exists "Site Admin reads transport type images" on storage.objects;
create policy "Site Admin reads transport type images" on storage.objects for select to authenticated
using(bucket_id='images' and pace_v2.is_site_admin() and (storage.foldername(name))[1]='transport-types');
drop policy if exists "Site Admin replaces transport type images" on storage.objects;
create policy "Site Admin replaces transport type images" on storage.objects for update to authenticated
using(bucket_id='images' and pace_v2.is_site_admin() and (storage.foldername(name))[1]='transport-types')
with check(bucket_id='images' and pace_v2.is_site_admin() and (storage.foldername(name))[1]='transport-types');
