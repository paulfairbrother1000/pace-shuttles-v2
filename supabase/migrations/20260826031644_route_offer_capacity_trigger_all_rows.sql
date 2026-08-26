-- Capacity is a physical invariant for active and historical Route Offers.
-- Commercial eligibility checks remain applicable only when an offer is active.

create or replace function pace_v2.validate_vehicle_route_offer()
returns trigger
language plpgsql
set search_path = pace_v2, public
as $$
declare
  v_operator_id uuid;
  v_vehicle_type_id uuid;
  v_capacity_seats integer;
  v_ok boolean;
begin
  -- Serialize Route Offer writes with capacity changes for this vehicle.
  select operator_id, vehicle_type_id, capacity_seats
    into v_operator_id, v_vehicle_type_id, v_capacity_seats
  from pace_v2.vehicles
  where id = new.vehicle_id
  for update;

  if v_operator_id is null then
    raise exception 'Vehicle % does not exist', new.vehicle_id;
  end if;

  if new.max_seats > v_capacity_seats then
    raise exception 'Route Offer maximum seats % exceed vehicle capacity %',
      new.max_seats, v_capacity_seats;
  end if;

  if not new.active then
    return new;
  end if;

  if not exists (
    select 1 from pace_v2.vehicles
    where id = new.vehicle_id and active = true
  ) then
    raise exception 'Vehicle % is inactive', new.vehicle_id;
  end if;

  select exists (
    select 1
    from pace_v2.operator_vehicle_types ovt
    where ovt.operator_id = v_operator_id
      and ovt.vehicle_type_id = v_vehicle_type_id
      and ovt.status = 'approved'
  ) into v_ok;

  if not v_ok then
    raise exception 'Operator is not approved for vehicle type %', v_vehicle_type_id;
  end if;

  select exists (
    select 1
    from pace_v2.route_vehicle_types rvt
    where rvt.route_id = new.route_id
      and rvt.vehicle_type_id = v_vehicle_type_id
      and rvt.active = true
      and rvt.effective_from <= now()
      and (rvt.effective_to is null or rvt.effective_to > now())
  ) into v_ok;

  if not v_ok then
    raise exception 'Vehicle type % is not permitted for route %',
      v_vehicle_type_id, new.route_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_vehicle_route_offer
  on pace_v2.vehicle_route_offers;

create trigger trg_validate_vehicle_route_offer
before insert or update on pace_v2.vehicle_route_offers
for each row execute function pace_v2.validate_vehicle_route_offer();
