begin;

do $$
declare
  v_offer pace_v2.vehicle_route_offers%rowtype;
  v_rejected boolean;
begin
  select * into v_offer
  from pace_v2.vehicle_route_offers
  where effective_to is null
  order by created_at
  limit 1;
  if v_offer.id is null then raise exception 'fixture: Route Offer missing'; end if;

  v_rejected := false;
  begin
    update pace_v2.vehicle_route_offers
    set below_minimum_operation_mode='custom_threshold', min_value_threshold_ratio=null
    where id=v_offer.id;
  exception when check_violation then v_rejected := true;
  end;
  if not v_rejected then raise exception 'custom threshold without a ratio was accepted'; end if;

  update pace_v2.vehicle_route_offers
  set below_minimum_operation_mode='never', min_value_threshold_ratio=null
  where id=v_offer.id;

  if exists (
    select 1 from pace_v2.vehicle_route_offers
    where id=v_offer.id and (below_minimum_operation_mode<>'never' or min_value_threshold_ratio is not null)
  ) then raise exception 'never mode was not stored unambiguously'; end if;

  update pace_v2.vehicle_route_offers
  set below_minimum_operation_mode='custom_threshold', min_value_threshold_ratio=.8
  where id=v_offer.id;

  if not exists (
    select 1 from pace_v2.vehicle_route_offers
    where id=v_offer.id and below_minimum_operation_mode='custom_threshold' and min_value_threshold_ratio=.8
  ) then raise exception 'custom threshold was not stored'; end if;
end
$$;

rollback;
