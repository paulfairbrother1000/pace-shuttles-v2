-- Route Offers are the commercial authority for a specific Vehicle + Route.
-- Vehicles retain only physical capacity as the authoritative fleet limit.

alter table pace_v2.vehicles
  add column if not exists capacity_seats integer;

update pace_v2.vehicles
set capacity_seats = default_max_seats
where capacity_seats is null;

do $$
begin
  if exists (
    select 1
    from pace_v2.vehicle_route_offers vro
    join pace_v2.vehicles v on v.id = vro.vehicle_id
    where vro.max_seats > v.capacity_seats
  ) then
    raise exception 'Existing Route Offer maximum seats exceed backfilled vehicle capacity';
  end if;
end
$$;

alter table pace_v2.vehicles
  alter column capacity_seats set not null;

alter table pace_v2.vehicles
  drop constraint if exists vehicle_capacity_seats_check;

alter table pace_v2.vehicles
  add constraint vehicle_capacity_seats_check
  check (capacity_seats > 0);

create unique index if not exists vehicle_route_offers_one_current_per_vehicle_route
  on pace_v2.vehicle_route_offers(vehicle_id, route_id)
  where active = true and effective_to is null;

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
  select operator_id, vehicle_type_id, capacity_seats
    into v_operator_id, v_vehicle_type_id, v_capacity_seats
  from pace_v2.vehicles
  where id = new.vehicle_id
    and active = true;

  if v_operator_id is null then
    raise exception 'Vehicle % is inactive or does not exist', new.vehicle_id;
  end if;

  if new.max_seats > v_capacity_seats then
    raise exception 'Route Offer maximum seats % exceed vehicle capacity %',
      new.max_seats, v_capacity_seats;
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

-- Preserve the current public RPC signature while treating p_max_seats as
-- physical capacity. The legacy commercial defaults remain populated only
-- until all clients have moved to the asset-only RPC contract.
create or replace function public.v2_admin_create_vehicle(
  p_operator_id uuid,
  p_vehicle_type_id uuid,
  p_name text,
  p_description text,
  p_min_seats integer,
  p_max_seats integer,
  p_min_revenue_cents integer,
  p_min_value_threshold_ratio numeric default null,
  p_max_seat_discount_bps integer default 0
)
returns uuid
language plpgsql
security definer
set search_path = public, pace_v2, auth
as $$
declare
  v_id uuid;
begin
  if not pace_v2.is_site_admin() then
    raise exception 'site admin required';
  end if;
  if trim(coalesce(p_name, '')) = '' then
    raise exception 'vehicle name required';
  end if;
  if p_max_seats is null or p_max_seats < 1 then
    raise exception 'physical vehicle capacity must be at least 1';
  end if;
  if not exists (
    select 1 from pace_v2.operators where id = p_operator_id
  ) then
    raise exception 'operator not found';
  end if;
  if not exists (
    select 1 from pace_v2.vehicle_types
    where id = p_vehicle_type_id and active
  ) then
    raise exception 'vehicle type not found or inactive';
  end if;

  insert into pace_v2.vehicles(
    operator_id, vehicle_type_id, name, description, capacity_seats,
    default_min_seats, default_max_seats, default_min_revenue_cents,
    default_min_value_threshold_ratio, default_max_seat_discount_bps, active
  ) values (
    p_operator_id, p_vehicle_type_id, trim(p_name),
    nullif(trim(coalesce(p_description, '')), ''), p_max_seats,
    p_min_seats, p_max_seats, p_min_revenue_cents,
    p_min_value_threshold_ratio, p_max_seat_discount_bps, true
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- Once seats have been assigned, the consideration is an auditable snapshot.
-- Refreshes may update an unallocated candidate but cannot rewrite commercial
-- terms already used for a customer allocation.
create or replace function pace_v2.protect_allocated_consideration_snapshot()
returns trigger
language plpgsql
set search_path = pace_v2, public
as $$
begin
  if old.assigned_seats > 0 and (
    new.vehicle_route_offer_id is distinct from old.vehicle_route_offer_id or
    new.normal_min_seats is distinct from old.normal_min_seats or
    new.max_seats is distinct from old.max_seats or
    new.min_revenue_cents is distinct from old.min_revenue_cents or
    new.min_value_threshold_ratio is distinct from old.min_value_threshold_ratio or
    new.normal_base_seat_price_cents is distinct from old.normal_base_seat_price_cents or
    new.effective_commission_bps is distinct from old.effective_commission_bps or
    new.effective_commission_source is distinct from old.effective_commission_source
  ) then
    raise exception 'Allocated vehicle consideration commercial snapshot is immutable';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_protect_allocated_consideration_snapshot
  on pace_v2.vehicle_considerations;

create trigger trg_protect_allocated_consideration_snapshot
before update on pace_v2.vehicle_considerations
for each row execute function pace_v2.protect_allocated_consideration_snapshot();
