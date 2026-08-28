-- Complete Site Admin operator create/edit contract and logo storage access.
create or replace function public.v2_admin_save_operator(
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
 p_cancellation_policy_id uuid default null
) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 if trim(coalesce(p_name,''))='' then raise exception 'operator name required'; end if;
 if trim(coalesce(p_admin_email,''))='' then raise exception 'operator admin email required'; end if;
 if p_country_id is null or not exists(select 1 from pace_v2.countries where id=p_country_id) then raise exception 'valid country required'; end if;
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
 return v_id;
end $$;

revoke all on function public.v2_admin_save_operator(uuid,text,uuid,text,text,text,text,text,text,text,uuid,uuid,text,text,text,text,boolean,boolean,uuid) from public,anon;
grant execute on function public.v2_admin_save_operator(uuid,text,uuid,text,text,text,text,text,text,text,uuid,uuid,text,text,text,text,boolean,boolean,uuid) to authenticated;

drop policy if exists "Site Admin uploads operator logos" on storage.objects;
create policy "Site Admin uploads operator logos" on storage.objects for insert to authenticated
with check(bucket_id='images' and pace_v2.is_site_admin() and (storage.foldername(name))[1]='operator-logos');
drop policy if exists "Site Admin reads operator logo objects" on storage.objects;
create policy "Site Admin reads operator logo objects" on storage.objects for select to authenticated
using(bucket_id='images' and pace_v2.is_site_admin() and (storage.foldername(name))[1]='operator-logos');
drop policy if exists "Site Admin replaces operator logos" on storage.objects;
create policy "Site Admin replaces operator logos" on storage.objects for update to authenticated
using(bucket_id='images' and pace_v2.is_site_admin() and (storage.foldername(name))[1]='operator-logos')
with check(bucket_id='images' and pace_v2.is_site_admin() and (storage.foldername(name))[1]='operator-logos');
