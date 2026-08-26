create or replace function pace_v2.validate_vehicle_capacity_change()
returns trigger
language plpgsql
set search_path = pace_v2, public
as $$
declare
  v_largest_offer integer;
begin
  select max(vro.max_seats)
    into v_largest_offer
  from pace_v2.vehicle_route_offers vro
  where vro.vehicle_id = new.id;

  if v_largest_offer is not null and new.capacity_seats < v_largest_offer then
    raise exception 'Vehicle capacity % is below existing Route Offer maximum seats %',
      new.capacity_seats, v_largest_offer;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_vehicle_capacity_change
  on pace_v2.vehicles;

create trigger trg_validate_vehicle_capacity_change
before update of capacity_seats on pace_v2.vehicles
for each row
when (new.capacity_seats is distinct from old.capacity_seats)
execute function pace_v2.validate_vehicle_capacity_change();

