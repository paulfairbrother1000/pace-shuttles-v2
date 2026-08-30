create table pace_v2.partner_api_client_requests (
  id bigint generated always as identity primary key,
  client_fingerprint_hash text not null,
  requested_at timestamptz not null default now()
);

create index partner_api_client_requests_hash_time_idx
  on pace_v2.partner_api_client_requests(client_fingerprint_hash,requested_at desc);

revoke all on pace_v2.partner_api_client_requests from public,anon,authenticated;

create or replace function public.v2_system_check_partner_api_rate_limit(p_client_fingerprint text)
returns boolean
language plpgsql
security definer
set search_path=''
as $$
declare
  v_hash text:=encode(extensions.digest(coalesce(p_client_fingerprint,''),'sha256'),'hex');
  v_count integer;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_hash,0));
  select count(*) into v_count
  from pace_v2.partner_api_client_requests
  where client_fingerprint_hash=v_hash and requested_at >= now()-interval '1 minute';
  if v_count >= 60 then return false; end if;
  insert into pace_v2.partner_api_client_requests(client_fingerprint_hash) values(v_hash);
  return true;
end
$$;

revoke all on function public.v2_system_check_partner_api_rate_limit(text) from public,anon,authenticated;
grant execute on function public.v2_system_check_partner_api_rate_limit(text) to service_role;

create or replace function public.v2_system_partner_shuttle_catalog(p_api_key text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_partner pace_v2.api_partners%rowtype;
  v_recent_requests integer;
  v_tiles jsonb;
begin
  if nullif(trim(coalesce(p_api_key,'')),'') is null then
    return jsonb_build_object('authorized',false);
  end if;

  select * into v_partner
  from pace_v2.api_partners
  where api_key_hash=encode(extensions.digest(p_api_key,'sha256'),'hex') and active
  limit 1
  for update;

  if v_partner.id is null then return jsonb_build_object('authorized',false); end if;

  select count(*) into v_recent_requests
  from pace_v2.partner_api_requests
  where partner_id=v_partner.id and requested_at >= now()-interval '1 minute';
  if v_recent_requests >= v_partner.rate_limit_per_minute then
    return jsonb_build_object('authorized',true,'rate_limited',true);
  end if;

  insert into pace_v2.partner_api_requests(partner_id) values(v_partner.id);
  update pace_v2.api_partners set last_used_at=now(),updated_at=now() where id=v_partner.id;

  with viable as (
    select distinct on(d.route_id)
      d.route_id,d.scheduled_departure_ts,eligible.vehicle_type_id
    from pace_v2.departures d
    cross join lateral pace_v2.get_eligible_vehicle_offers(d.id) eligible
    where d.scheduled_departure_ts > now()
      and d.status in ('scheduled','selling','at_risk','under_consideration')
    order by d.route_id,d.scheduled_departure_ts,eligible.vehicle_type_id
  )
  select coalesce(jsonb_agg(tile order by tile->>'route_name'),'[]'::jsonb) into v_tiles
  from (
    select jsonb_build_object(
      'route_id',r.id,
      'country',c.name,
      'vehicle_type',vt.name,
      'route_name',r.route_name,
      'pickup',jsonb_build_object('id',p.id,'name',p.name,'image_url',p.picture_url),
      'destination',jsonb_build_object('id',dst.id,'name',dst.name,'image_url',dst.picture_url),
      'schedule',nullif(trim(coalesce(r.frequency,'')),'')
    ) as tile
    from viable
    join pace_v2.routes r on r.id=viable.route_id and r.is_active
    join pace_v2.countries c on c.id=r.country_id and c.active
    join pace_v2.pickup_points p on p.id=r.pickup_id and p.active
    join pace_v2.destinations dst on dst.id=r.destination_id and dst.active and dst.published_at is not null
    join pace_v2.vehicle_types vt on vt.id=viable.vehicle_type_id and vt.active
    where r.country_id=v_partner.country_id
  ) catalogue;

  return jsonb_build_object(
    'authorized',true,
    'partner',jsonb_build_object('id',v_partner.id,'name',v_partner.name),
    'country_id',v_partner.country_id,
    'tiles',v_tiles
  );
end
$$;

revoke all on function public.v2_system_partner_shuttle_catalog(text) from public,anon,authenticated;
grant execute on function public.v2_system_partner_shuttle_catalog(text) to service_role;

