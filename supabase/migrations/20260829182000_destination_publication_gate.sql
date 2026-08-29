alter table pace_v2.destinations add column if not exists published_at timestamptz;
alter table pace_v2.destinations add column if not exists published_by uuid references auth.users(id);

update pace_v2.destinations
set published_at=coalesce(published_at,created_at,now())
where active and published_at is null;

create or replace function public.v2_admin_set_destination_published(p_destination_id uuid,p_published boolean)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 v_destination pace_v2.destinations%rowtype;
 v_country pace_v2.countries%rowtype;
 v_missing text[]:='{}'::text[];
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 select * into v_destination from pace_v2.destinations where id=p_destination_id for update;
 if v_destination.id is null then raise exception 'destination not found'; end if;

 if not coalesce(p_published,false) then
  update pace_v2.destinations set active=false,updated_at=now() where id=p_destination_id;
  return p_destination_id;
 end if;

 if v_destination.country_id is null then
  v_missing:=array_append(v_missing,'country');
 else
  select * into v_country from pace_v2.countries where id=v_destination.country_id and active;
  if v_country.id is null then v_missing:=array_append(v_missing,'active country'); end if;
 end if;
 if coalesce(v_country.is_large,false) and v_destination.region_id is null then v_missing:=array_append(v_missing,coalesce(v_country.region_label,'region')); end if;
 if coalesce(v_country.is_large,false) and v_destination.locality_id is null then v_missing:=array_append(v_missing,coalesce(v_country.locality_label,'locality')); end if;
 if nullif(trim(coalesce(v_destination.name,'')),'') is null then v_missing:=array_append(v_missing,'name'); end if;
 if nullif(trim(coalesce(v_destination.destination_type,'')),'') is null then v_missing:=array_append(v_missing,'destination type'); end if;
 if nullif(trim(coalesce(v_destination.description,'')),'') is null then v_missing:=array_append(v_missing,'description'); end if;
 if nullif(trim(coalesce(v_destination.picture_url,'')),'') is null then v_missing:=array_append(v_missing,'picture'); end if;
 if nullif(trim(coalesce(v_destination.address1,'')),'') is null and nullif(trim(coalesce(v_destination.town,'')),'') is null
 then v_missing:=array_append(v_missing,'address or town'); end if;
 if v_destination.latitude is null or v_destination.latitude < -90 or v_destination.latitude > 90 then v_missing:=array_append(v_missing,'valid latitude'); end if;
 if v_destination.longitude is null or v_destination.longitude < -180 or v_destination.longitude > 180 then v_missing:=array_append(v_missing,'valid longitude'); end if;
 if v_destination.directions_url is null or v_destination.directions_url !~* '^https://([^/]+\.)?(google\.[a-z.]+|goo\.gl)/'
 then v_missing:=array_append(v_missing,'Google Maps directions link'); end if;
 if v_destination.wet_or_dry not in ('wet','dry') then v_missing:=array_append(v_missing,'wet or dry arrival type'); end if;
 if nullif(trim(coalesce(v_destination.arrival_notes,'')),'') is null then v_missing:=array_append(v_missing,'arrival instructions'); end if;
 if nullif(trim(coalesce(v_destination.email,'')),'') is null and nullif(trim(coalesce(v_destination.phone,'')),'') is null
 then v_missing:=array_append(v_missing,'contact email or telephone'); end if;

 if cardinality(v_missing)>0 then
  raise exception using errcode='22023',message='destination cannot be published: '||array_to_string(v_missing,', ');
 end if;

 update pace_v2.destinations set active=true,published_at=now(),published_by=auth.uid(),updated_at=now()
 where id=p_destination_id;
 return p_destination_id;
end
$$;

revoke all on function public.v2_admin_set_destination_published(uuid,boolean) from public,anon;
grant execute on function public.v2_admin_set_destination_published(uuid,boolean) to authenticated;

create or replace view public.v2_public_destinations as
select id,country_id,name,town,region,picture_url,description,wet_or_dry,url,gift,arrival_notes,region_id,locality_id,
 sort_order,address1,address2,postal_code,phone,destination_type,email,directions_url,latitude,longitude
from pace_v2.destinations d
where active and published_at is not null;
revoke all on public.v2_public_destinations from public,anon,authenticated;
grant select on public.v2_public_destinations to anon,authenticated;

create or replace view public.v2_destinations with (security_invoker=true) as
select id,country_id,name,address1,address2,town,region,postal_code,phone,picture_url,description,season_from,season_to,
 destination_type,wet_or_dry,url,gift,arrival_notes,email,region_id,locality_id,latitude,longitude,active,sort_order,
 v1_source_id,created_at,updated_at,directions_url,published_at,published_by
from pace_v2.destinations where pace_v2.is_site_admin();
revoke all on public.v2_destinations from public,anon,authenticated;
grant select on public.v2_destinations to authenticated;
