create table pace_v2.api_partners (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  key_prefix text not null,
  api_key_hash text not null unique,
  country_id uuid not null references pace_v2.countries(id),
  active boolean not null default true,
  rate_limit_per_minute integer not null default 120 check (rate_limit_per_minute between 1 and 10000),
  last_used_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table pace_v2.partner_api_requests (
  id bigint generated always as identity primary key,
  partner_id uuid not null references pace_v2.api_partners(id) on delete cascade,
  requested_at timestamptz not null default now()
);

create index partner_api_requests_partner_time_idx
  on pace_v2.partner_api_requests(partner_id,requested_at desc);

revoke all on pace_v2.api_partners from public,anon,authenticated;
revoke all on pace_v2.partner_api_requests from public,anon,authenticated;

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
  where api_key_hash=encode(extensions.digest(p_api_key,'sha256'),'hex')
    and active
  limit 1;

  if v_partner.id is null then
    return jsonb_build_object('authorized',false);
  end if;

  select count(*) into v_recent_requests
  from pace_v2.partner_api_requests
  where partner_id=v_partner.id and requested_at >= now()-interval '1 minute';

  if v_recent_requests >= v_partner.rate_limit_per_minute then
    return jsonb_build_object('authorized',true,'rate_limited',true);
  end if;

  insert into pace_v2.partner_api_requests(partner_id) values(v_partner.id);
  update pace_v2.api_partners set last_used_at=now(),updated_at=now() where id=v_partner.id;

  select coalesce(jsonb_agg(tile order by tile->>'route_name'),'[]'::jsonb) into v_tiles
  from (
    select jsonb_build_object(
      'route_id',r.id,
      'country',c.name,
      'vehicle_type',coalesce((
        select vt.name
        from pace_v2.route_vehicle_types rvt
        join pace_v2.vehicle_types vt on vt.id=rvt.vehicle_type_id and vt.active
        where rvt.route_id=r.id and rvt.active and rvt.effective_to is null
        order by vt.display_order,vt.name
        limit 1
      ),'Shuttle'),
      'route_name',r.route_name,
      'pickup',jsonb_build_object('id',p.id,'name',p.name,'image_url',p.picture_url),
      'destination',jsonb_build_object('id',dst.id,'name',dst.name,'image_url',dst.picture_url),
      'schedule',nullif(trim(coalesce(r.frequency,'')),'')
    ) as tile
    from pace_v2.routes r
    join pace_v2.countries c on c.id=r.country_id and c.active
    join pace_v2.pickup_points p on p.id=r.pickup_id and p.active
    join pace_v2.destinations dst on dst.id=r.destination_id and dst.active and dst.published_at is not null
    where r.country_id=v_partner.country_id
      and r.is_active
      and exists(
        select 1 from pace_v2.departures d
        where d.route_id=r.id
          and d.scheduled_departure_ts > now()
          and d.status in ('scheduled','selling','at_risk','under_consideration')
      )
      and exists(
        select 1 from pace_v2.route_vehicle_types rvt
        join pace_v2.vehicle_types vt on vt.id=rvt.vehicle_type_id and vt.active
        where rvt.route_id=r.id and rvt.active and rvt.effective_to is null
      )
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

