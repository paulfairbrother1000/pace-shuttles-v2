begin;

do $$
declare
  v_capacity_nullable text;
begin
  select is_nullable
    into v_capacity_nullable
  from information_schema.columns
  where table_schema = 'pace_v2'
    and table_name = 'vehicles'
    and column_name = 'capacity_seats';

  if v_capacity_nullable is distinct from 'NO' then
    raise exception 'vehicles.capacity_seats must exist and be NOT NULL';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'v2_vehicles'
      and column_name = 'capacity_seats'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'v2_operator_my_fleet'
      and column_name = 'capacity_seats'
  ) then
    raise exception 'vehicle API views must expose physical capacity';
  end if;

  if not exists (
    select 1
    from pg_indexes
    where schemaname = 'pace_v2'
      and tablename = 'vehicle_route_offers'
      and indexname = 'vehicle_route_offers_one_current_per_vehicle_service'
      and indexdef ilike '%unique%'
  ) then
    raise exception 'current Vehicle + Service offers must be unique';
  end if;

  if not exists (
    select 1
    from information_schema.triggers
    where trigger_schema = 'pace_v2'
      and event_object_table = 'vehicle_route_offers'
      and trigger_name = 'trg_validate_vehicle_route_offer'
      and action_condition is null
  ) then
    raise exception 'Route Offer validation trigger must cover active and historical rows';
  end if;

  if not exists (
    select 1
    from information_schema.triggers
    where trigger_schema = 'pace_v2'
      and event_object_table = 'vehicles'
      and trigger_name = 'trg_validate_vehicle_capacity_change'
  ) then
    raise exception 'vehicle capacity changes must preserve Route Offer limits';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'pace_v2'
      and table_name = 'vehicle_considerations'
      and column_name = 'post_min_discount_enabled'
      and is_nullable = 'NO'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'pace_v2'
      and table_name = 'vehicle_considerations'
      and column_name = 'post_min_discount_bps'
      and is_nullable = 'NO'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'pace_v2'
      and table_name = 'vehicle_considerations'
      and column_name = 'commercial_snapshot_locked_at'
  ) then
    raise exception 'considerations must snapshot discount terms with a durable lock';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'pace_v2' and table_name = 'vehicles'
      and column_name = 'capacity_source' and is_nullable = 'NO'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'pace_v2' and table_name = 'vehicles'
      and column_name = 'capacity_verified_at'
  ) then
    raise exception 'vehicle capacity must carry source and verification provenance';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'pace_v2' and table_name = 'vehicle_considerations'
      and column_name = 'commercial_snapshot_source' and is_nullable = 'NO'
  ) then
    raise exception 'commercial snapshots must disclose their provenance';
  end if;


  if exists (
    select 1
    from pace_v2.vehicle_route_offers vro
    join pace_v2.vehicles v on v.id = vro.vehicle_id
    where vro.max_seats > v.capacity_seats
  ) then
    raise exception 'Route Offer maximum seats exceed physical vehicle capacity';
  end if;
end
$$;

rollback;
