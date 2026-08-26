begin;

do $service_specific_offers_behavior$
declare
  v_source_offer pace_v2.vehicle_route_offers%rowtype;
  v_route_id uuid := gen_random_uuid();
  v_saturday_service_id uuid := gen_random_uuid();
  v_tuesday_service_id uuid := gen_random_uuid();
  v_saturday_departure_id uuid := gen_random_uuid();
  v_tuesday_departure_id uuid := gen_random_uuid();
  v_vehicle_id uuid := gen_random_uuid();
  v_saturday_offer_id uuid;
  v_tuesday_offer_id uuid;
  v_vehicle_type_id uuid;
  v_timezone text;
  v_saturday_date date;
  v_tuesday_date date;
  v_saturday_departure_ts timestamptz;
  v_tuesday_departure_ts timestamptz;
  v_offer_ids uuid[];
begin
  select vro.* into v_source_offer
  from pace_v2.vehicle_route_offers vro
  join pace_v2.vehicles v
    on v.id=vro.vehicle_id and v.active
  join pace_v2.operators o
    on o.id=v.operator_id and o.active
  join pace_v2.operator_vehicle_types ovt
    on ovt.operator_id=v.operator_id
   and ovt.vehicle_type_id=v.vehicle_type_id
   and ovt.status='approved'
  where vro.active
    and vro.effective_to is null
  order by vro.created_at,vro.id
  limit 1;

  if not found then
    raise exception 'fixture: active current vehicle offer with approved operator is required';
  end if;

  select v.vehicle_type_id into v_vehicle_type_id
  from pace_v2.vehicles v
  where v.id=v_source_offer.vehicle_id;

  insert into pace_v2.vehicles(
    id,operator_id,vehicle_type_id,name,description,picture_url,active,
    default_min_seats,default_max_seats,default_min_revenue_cents,
    default_min_value_threshold_ratio,default_max_seat_discount_bps,
    capacity_seats,capacity_source,capacity_verified_at
  )
  select
    v_vehicle_id,v.operator_id,v.vehicle_type_id,
    'Service allocation behavior vehicle',null,null,true,
    v.default_min_seats,v.default_max_seats,v.default_min_revenue_cents,
    v.default_min_value_threshold_ratio,v.default_max_seat_discount_bps,
    v.capacity_seats,'site_admin_entry',now()
  from pace_v2.vehicles v
  where v.id=v_source_offer.vehicle_id;

  insert into pace_v2.routes(
    id,route_name,name,trip_timezone,pickup_id,destination_id,country_id,
    is_active,market_id,region_id,locality_id,approx_duration_mins,
    booking_lead_time_hours,t72_hours,t24_hours
  )
  select
    v_route_id,'Service allocation behavior route','Service allocation behavior route',
    r.trip_timezone,r.pickup_id,r.destination_id,r.country_id,
    true,r.market_id,r.region_id,r.locality_id,coalesce(r.approx_duration_mins,120),
    r.booking_lead_time_hours,r.t72_hours,r.t24_hours
  from pace_v2.routes r
  where r.id=v_source_offer.route_id
  returning trip_timezone into v_timezone;

  insert into pace_v2.route_vehicle_types(
    route_id,vehicle_type_id,active,effective_from,effective_to
  ) values (
    v_route_id,v_vehicle_type_id,true,now()-interval '1 day',null
  );

  insert into pace_v2.services(
    id,route_id,name,active,timezone,days_of_week,departure_time,
    valid_from,valid_to
  ) values
    (v_saturday_service_id,v_route_id,'Saturday allocation behavior service',true,
     v_timezone,array[6]::smallint[],time '10:00',current_date,null),
    (v_tuesday_service_id,v_route_id,'Tuesday allocation behavior service',true,
     v_timezone,array[2]::smallint[],time '11:00',current_date,null);

  v_saturday_date := current_date
    + ((6-extract(isodow from current_date)::integer+7)%7)
    + 14;
  v_tuesday_date := current_date
    + ((2-extract(isodow from current_date)::integer+7)%7)
    + 14;
  v_saturday_departure_ts := (v_saturday_date::timestamp+time '10:00') at time zone v_timezone;
  v_tuesday_departure_ts := (v_tuesday_date::timestamp+time '11:00') at time zone v_timezone;

  insert into pace_v2.departures(
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
    trip_timezone,local_departure_date,t72_ts,t24_ts,status
  ) values
    (v_saturday_departure_id,v_saturday_service_id,v_route_id,
     v_saturday_departure_ts,v_saturday_departure_ts+interval '2 hours',
     v_timezone,v_saturday_date,v_saturday_departure_ts-interval '72 hours',
     v_saturday_departure_ts-interval '24 hours','scheduled'),
    (v_tuesday_departure_id,v_tuesday_service_id,v_route_id,
     v_tuesday_departure_ts,v_tuesday_departure_ts+interval '2 hours',
     v_timezone,v_tuesday_date,v_tuesday_departure_ts-interval '72 hours',
     v_tuesday_departure_ts-interval '24 hours','scheduled');

  insert into pace_v2.vehicle_route_offers(
    vehicle_id,service_id,route_id,preferred_captain_id,preferred,active,
    min_seats,max_seats,min_revenue_cents,min_value_threshold_ratio,
    below_minimum_operation_mode,post_min_discount_enabled,
    post_min_discount_bps,effective_from,effective_to
  ) values (
    v_vehicle_id,v_saturday_service_id,v_route_id,
    null,v_source_offer.preferred,true,
    v_source_offer.min_seats,v_source_offer.max_seats,
    v_source_offer.min_revenue_cents,v_source_offer.min_value_threshold_ratio,
    v_source_offer.below_minimum_operation_mode,
    v_source_offer.post_min_discount_enabled,v_source_offer.post_min_discount_bps,
    now()-interval '1 day',null
  ) returning id into v_saturday_offer_id;

  select array_agg(e.vehicle_route_offer_id order by e.vehicle_route_offer_id)
  into v_offer_ids
  from pace_v2.get_eligible_vehicle_offers(v_saturday_departure_id) e;
  if v_offer_ids is distinct from array[v_saturday_offer_id] then
    raise exception 'Saturday departure did not resolve only its Saturday offer: %',v_offer_ids;
  end if;

  if exists (
    select 1
    from pace_v2.get_eligible_vehicle_offers(v_tuesday_departure_id)
  ) then
    raise exception 'Tuesday departure admitted a route-only Saturday offer';
  end if;

  insert into pace_v2.vehicle_route_offers(
    vehicle_id,service_id,route_id,preferred_captain_id,preferred,active,
    min_seats,max_seats,min_revenue_cents,min_value_threshold_ratio,
    below_minimum_operation_mode,post_min_discount_enabled,
    post_min_discount_bps,effective_from,effective_to
  ) values (
    v_vehicle_id,v_tuesday_service_id,v_route_id,
    null,v_source_offer.preferred,true,
    v_source_offer.min_seats,v_source_offer.max_seats,
    v_source_offer.min_revenue_cents,v_source_offer.min_value_threshold_ratio,
    v_source_offer.below_minimum_operation_mode,
    v_source_offer.post_min_discount_enabled,v_source_offer.post_min_discount_bps,
    now()-interval '1 day',null
  ) returning id into v_tuesday_offer_id;

  select array_agg(e.vehicle_route_offer_id order by e.vehicle_route_offer_id)
  into v_offer_ids
  from pace_v2.get_eligible_vehicle_offers(v_saturday_departure_id) e;
  if v_offer_ids is distinct from array[v_saturday_offer_id] then
    raise exception 'Saturday departure crossed into another service offer: %',v_offer_ids;
  end if;

  select array_agg(e.vehicle_route_offer_id order by e.vehicle_route_offer_id)
  into v_offer_ids
  from pace_v2.get_eligible_vehicle_offers(v_tuesday_departure_id) e;
  if v_offer_ids is distinct from array[v_tuesday_offer_id] then
    raise exception 'Tuesday departure did not resolve only its Tuesday offer: %',v_offer_ids;
  end if;
end
$service_specific_offers_behavior$;

rollback;
