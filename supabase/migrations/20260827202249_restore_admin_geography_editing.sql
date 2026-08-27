-- Restore the V1 geography editing contract in the V2 Site Admin interface.
-- This migration is intentionally additive: existing rows, URLs and legacy RPCs remain intact.

alter table pace_v2.destinations add column if not exists directions_url text;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('images','images',true,8388608,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict(id) do update set
 public=excluded.public,
 file_size_limit=excluded.file_size_limit,
 allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "Site Admin uploads geography images" on storage.objects;
create policy "Site Admin uploads geography images" on storage.objects
 for insert to authenticated
 with check (
  bucket_id='images' and pace_v2.is_site_admin() and
  (storage.foldername(name))[1] in ('countries','pickup-points','destinations')
 );

drop policy if exists "Site Admin reads geography image objects" on storage.objects;
create policy "Site Admin reads geography image objects" on storage.objects
 for select to authenticated
 using (
  bucket_id='images' and pace_v2.is_site_admin() and
  (storage.foldername(name))[1] in ('countries','pickup-points','destinations')
 );

drop policy if exists "Site Admin replaces geography images" on storage.objects;
create policy "Site Admin replaces geography images" on storage.objects
 for update to authenticated
 using (
  bucket_id='images' and pace_v2.is_site_admin() and
  (storage.foldername(name))[1] in ('countries','pickup-points','destinations')
 )
 with check (
  bucket_id='images' and pace_v2.is_site_admin() and
  (storage.foldername(name))[1] in ('countries','pickup-points','destinations')
 );

create or replace function public.v2_admin_save_country(
 p_country_id uuid,
 p_name text,
 p_code text,
 p_description text default null,
 p_picture_url text default null,
 p_timezone text default null,
 p_is_large boolean default false,
 p_region_label text default 'Region',
 p_locality_label text default 'Town / City',
 p_active boolean default true
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 if trim(coalesce(p_name,''))='' then raise exception 'country name required'; end if;
 if trim(coalesce(p_code,''))='' then raise exception 'country code required'; end if;
 if p_country_id is null then
  insert into pace_v2.countries(name,code,description,picture_url,timezone,is_large,region_label,locality_label,active,display_order)
  values(trim(p_name),upper(trim(p_code)),nullif(trim(coalesce(p_description,'')),''),nullif(trim(coalesce(p_picture_url,'')),''),
   nullif(trim(coalesce(p_timezone,'')),''),coalesce(p_is_large,false),coalesce(nullif(trim(p_region_label),''),'Region'),
   coalesce(nullif(trim(p_locality_label),''),'Town / City'),coalesce(p_active,true),
   coalesce((select max(display_order)+10 from pace_v2.countries),10)) returning id into v_id;
 else
  update pace_v2.countries set name=trim(p_name),code=upper(trim(p_code)),description=nullif(trim(coalesce(p_description,'')),''),
   picture_url=nullif(trim(coalesce(p_picture_url,'')),''),timezone=nullif(trim(coalesce(p_timezone,'')),''),
   is_large=coalesce(p_is_large,false),region_label=coalesce(nullif(trim(p_region_label),''),'Region'),
   locality_label=coalesce(nullif(trim(p_locality_label),''),'Town / City'),active=coalesce(p_active,true),updated_at=now()
  where id=p_country_id returning id into v_id;
  if v_id is null then raise exception 'country not found'; end if;
 end if;
 return v_id;
end $$;

create or replace function public.v2_admin_save_pickup(
 p_pickup_id uuid,p_country_id uuid,p_name text,p_address1 text default null,p_address2 text default null,
 p_town text default null,p_region text default null,p_postal_code text default null,p_picture_url text default null,
 p_description text default null,p_transport_type_id uuid default null,p_transport_type_place_id uuid default null,
 p_arrival_notes text default null,p_directions_url text default null,p_region_id uuid default null,p_locality_id uuid default null,
 p_latitude numeric default null,p_longitude numeric default null,p_active boolean default true
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 if trim(coalesce(p_name,''))='' then raise exception 'pickup name required'; end if;
 if p_country_id is null then raise exception 'country required'; end if;
 if p_directions_url is not null and p_directions_url !~* '^https://([^/]+\.)?(google\.[a-z.]+|goo\.gl)/' then raise exception 'valid Google Maps link required'; end if;
 if p_pickup_id is null then
  insert into pace_v2.pickup_points(country_id,name,address1,address2,town,region,postal_code,picture_url,description,transport_type_id,
   transport_type_place_id,arrival_notes,directions_url,region_id,locality_id,latitude,longitude,active)
  values(p_country_id,trim(p_name),nullif(trim(coalesce(p_address1,'')),''),nullif(trim(coalesce(p_address2,'')),''),
   nullif(trim(coalesce(p_town,'')),''),nullif(trim(coalesce(p_region,'')),''),nullif(trim(coalesce(p_postal_code,'')),''),
   nullif(trim(coalesce(p_picture_url,'')),''),nullif(trim(coalesce(p_description,'')),''),p_transport_type_id,p_transport_type_place_id,
   nullif(trim(coalesce(p_arrival_notes,'')),''),nullif(trim(coalesce(p_directions_url,'')),''),p_region_id,p_locality_id,p_latitude,p_longitude,coalesce(p_active,true))
  returning id into v_id;
 else
  update pace_v2.pickup_points set country_id=p_country_id,name=trim(p_name),address1=nullif(trim(coalesce(p_address1,'')),''),
   address2=nullif(trim(coalesce(p_address2,'')),''),town=nullif(trim(coalesce(p_town,'')),''),region=nullif(trim(coalesce(p_region,'')),''),
   postal_code=nullif(trim(coalesce(p_postal_code,'')),''),picture_url=nullif(trim(coalesce(p_picture_url,'')),''),
   description=nullif(trim(coalesce(p_description,'')),''),transport_type_id=p_transport_type_id,transport_type_place_id=p_transport_type_place_id,
   arrival_notes=nullif(trim(coalesce(p_arrival_notes,'')),''),directions_url=nullif(trim(coalesce(p_directions_url,'')),''),
   region_id=p_region_id,locality_id=p_locality_id,latitude=p_latitude,longitude=p_longitude,active=coalesce(p_active,true),updated_at=now()
  where id=p_pickup_id returning id into v_id;
  if v_id is null then raise exception 'pickup not found'; end if;
 end if;
 return v_id;
end $$;

create or replace function public.v2_admin_save_destination(
 p_destination_id uuid,p_country_id uuid,p_name text,p_address1 text default null,p_address2 text default null,
 p_town text default null,p_region text default null,p_postal_code text default null,p_phone text default null,p_picture_url text default null,
 p_description text default null,p_season_from date default null,p_season_to date default null,p_destination_type text default null,
 p_wet_or_dry text default null,p_url text default null,p_gift text default null,p_arrival_notes text default null,p_email text default null,
 p_directions_url text default null,p_region_id uuid default null,p_locality_id uuid default null,p_latitude numeric default null,
 p_longitude numeric default null,p_active boolean default true
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 if trim(coalesce(p_name,''))='' then raise exception 'destination name required'; end if;
 if p_country_id is null then raise exception 'country required'; end if;
 if p_wet_or_dry is not null and p_wet_or_dry not in ('wet','dry') then raise exception 'wet_or_dry must be wet or dry'; end if;
 if p_season_from is not null and p_season_to is not null and p_season_to<p_season_from then raise exception 'season end must not precede season start'; end if;
 if p_directions_url is not null and p_directions_url !~* '^https://([^/]+\.)?(google\.[a-z.]+|goo\.gl)/' then raise exception 'valid Google Maps link required'; end if;
 if p_destination_id is null then
  insert into pace_v2.destinations(country_id,name,address1,address2,town,region,postal_code,phone,picture_url,description,season_from,season_to,
   destination_type,wet_or_dry,url,gift,arrival_notes,email,directions_url,region_id,locality_id,latitude,longitude,active)
  values(p_country_id,trim(p_name),nullif(trim(coalesce(p_address1,'')),''),nullif(trim(coalesce(p_address2,'')),''),
   nullif(trim(coalesce(p_town,'')),''),nullif(trim(coalesce(p_region,'')),''),nullif(trim(coalesce(p_postal_code,'')),''),
   nullif(trim(coalesce(p_phone,'')),''),nullif(trim(coalesce(p_picture_url,'')),''),nullif(trim(coalesce(p_description,'')),''),
   p_season_from,p_season_to,nullif(trim(coalesce(p_destination_type,'')),''),p_wet_or_dry,nullif(trim(coalesce(p_url,'')),''),
   nullif(trim(coalesce(p_gift,'')),''),nullif(trim(coalesce(p_arrival_notes,'')),''),nullif(trim(coalesce(p_email,'')),''),
   nullif(trim(coalesce(p_directions_url,'')),''),p_region_id,p_locality_id,p_latitude,p_longitude,coalesce(p_active,true)) returning id into v_id;
 else
  update pace_v2.destinations set country_id=p_country_id,name=trim(p_name),address1=nullif(trim(coalesce(p_address1,'')),''),
   address2=nullif(trim(coalesce(p_address2,'')),''),town=nullif(trim(coalesce(p_town,'')),''),region=nullif(trim(coalesce(p_region,'')),''),
   postal_code=nullif(trim(coalesce(p_postal_code,'')),''),phone=nullif(trim(coalesce(p_phone,'')),''),picture_url=nullif(trim(coalesce(p_picture_url,'')),''),
   description=nullif(trim(coalesce(p_description,'')),''),season_from=p_season_from,season_to=p_season_to,destination_type=nullif(trim(coalesce(p_destination_type,'')),''),
   wet_or_dry=p_wet_or_dry,url=nullif(trim(coalesce(p_url,'')),''),gift=nullif(trim(coalesce(p_gift,'')),''),arrival_notes=nullif(trim(coalesce(p_arrival_notes,'')),''),
   email=nullif(trim(coalesce(p_email,'')),''),directions_url=nullif(trim(coalesce(p_directions_url,'')),''),region_id=p_region_id,locality_id=p_locality_id,
   latitude=p_latitude,longitude=p_longitude,active=coalesce(p_active,true),updated_at=now()
  where id=p_destination_id returning id into v_id;
  if v_id is null then raise exception 'destination not found'; end if;
 end if;
 return v_id;
end $$;

create or replace function public.v2_admin_list_transport_type_places()
returns table(id uuid,transport_type_id uuid,name text,description text,active boolean)
language sql security definer set search_path='' as $$
 select p.id,p.transport_type_id,p.name,p.description,p.active
 from pace_v2.transport_type_places p
 where pace_v2.is_site_admin() and p.active
 order by p.name
$$;

revoke all on function public.v2_admin_save_country(uuid,text,text,text,text,text,boolean,text,text,boolean) from public;
revoke all on function public.v2_admin_save_pickup(uuid,uuid,text,text,text,text,text,text,text,text,uuid,uuid,text,text,uuid,uuid,numeric,numeric,boolean) from public;
revoke all on function public.v2_admin_save_destination(uuid,uuid,text,text,text,text,text,text,text,text,text,date,date,text,text,text,text,text,text,text,uuid,uuid,numeric,numeric,boolean) from public;
revoke all on function public.v2_admin_list_transport_type_places() from public;
grant execute on function public.v2_admin_save_country(uuid,text,text,text,text,text,boolean,text,text,boolean) to authenticated;
grant execute on function public.v2_admin_save_pickup(uuid,uuid,text,text,text,text,text,text,text,text,uuid,uuid,text,text,uuid,uuid,numeric,numeric,boolean) to authenticated;
grant execute on function public.v2_admin_save_destination(uuid,uuid,text,text,text,text,text,text,text,text,text,date,date,text,text,text,text,text,text,text,uuid,uuid,numeric,numeric,boolean) to authenticated;
grant execute on function public.v2_admin_list_transport_type_places() to authenticated;

drop policy if exists destinations_admin_read on pace_v2.destinations;
create policy destinations_admin_read on pace_v2.destinations for select to authenticated
 using (pace_v2.is_site_admin());
grant usage on schema pace_v2 to authenticated;
grant select on pace_v2.destinations to authenticated;

create or replace view public.v2_destinations with (security_invoker=true) as
select id,country_id,name,address1,address2,town,region,postal_code,phone,picture_url,description,season_from,season_to,
 destination_type,wet_or_dry,url,gift,arrival_notes,email,region_id,locality_id,latitude,longitude,active,sort_order,
 v1_source_id,created_at,updated_at,directions_url
from pace_v2.destinations where pace_v2.is_site_admin();
revoke all on public.v2_destinations from public,anon;
grant select on public.v2_destinations to authenticated;
