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
  limit 1 for update;
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
      d.route_id,d.scheduled_departure_ts,v.vehicle_type_id
    from pace_v2.departures d
    join pace_v2.routes r on r.id=d.route_id and r.is_active and r.country_id=v_partner.country_id
    join pace_v2.vehicle_route_offers vro on vro.service_id=d.service_id and vro.active
      and vro.effective_from<=d.scheduled_departure_ts
      and (vro.effective_to is null or vro.effective_to>d.scheduled_departure_ts)
    join pace_v2.vehicles v on v.id=vro.vehicle_id and v.active
    join pace_v2.operators o on o.id=v.operator_id and o.active
    join pace_v2.operator_vehicle_types ovt on ovt.operator_id=v.operator_id
      and ovt.vehicle_type_id=v.vehicle_type_id and ovt.status='approved'
    join pace_v2.route_vehicle_types rvt on rvt.route_id=d.route_id
      and rvt.vehicle_type_id=v.vehicle_type_id and rvt.active
      and rvt.effective_from<=d.scheduled_departure_ts
      and (rvt.effective_to is null or rvt.effective_to>d.scheduled_departure_ts)
    where d.scheduled_departure_ts>now()
      and d.status in ('scheduled','selling','at_risk','under_consideration')
      and not exists(
        select 1 from pace_v2.vehicle_availability_exceptions vae
        where vae.vehicle_id=v.id
          and vae.start_ts<coalesce(d.scheduled_arrival_ts,d.scheduled_departure_ts+interval '8 hours')
          and vae.end_ts>d.scheduled_departure_ts
      )
    order by d.route_id,d.scheduled_departure_ts,v.vehicle_type_id
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
