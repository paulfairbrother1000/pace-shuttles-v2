alter table pace_v2.vehicles
  add column if not exists capacity_source text,
  add column if not exists capacity_verified_at timestamptz;

update pace_v2.vehicles
set capacity_source = 'legacy_default_max_seats',
    capacity_verified_at = null
where capacity_source is null;

alter table pace_v2.vehicles
  alter column capacity_source set default 'site_admin_entry',
  alter column capacity_source set not null;

alter table pace_v2.vehicle_considerations
  add column if not exists commercial_snapshot_source text;

update pace_v2.vehicle_considerations
set commercial_snapshot_source = case
  when commercial_snapshot_locked_at is not null
    then 'legacy_route_offer_backfill_unverified'
  else 'legacy_route_offer_live_backfill'
end
where commercial_snapshot_source is null;

alter table pace_v2.vehicle_considerations
  alter column commercial_snapshot_source
    set default 'route_offer_at_consideration',
  alter column commercial_snapshot_source set not null;

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
  if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
  if trim(coalesce(p_name, '')) = '' then raise exception 'vehicle name required'; end if;
  if p_max_seats is null or p_max_seats < 1 then
    raise exception 'physical vehicle capacity must be at least 1';
  end if;
  if not exists (select 1 from pace_v2.operators where id=p_operator_id) then
    raise exception 'operator not found';
  end if;
  if not exists (
    select 1 from pace_v2.vehicle_types
    where id=p_vehicle_type_id and active
  ) then
    raise exception 'vehicle type not found or inactive';
  end if;

  insert into pace_v2.vehicles(
    operator_id,vehicle_type_id,name,description,capacity_seats,
    capacity_source,capacity_verified_at,
    default_min_seats,default_max_seats,default_min_revenue_cents,
    default_min_value_threshold_ratio,default_max_seat_discount_bps,active
  ) values (
    p_operator_id,p_vehicle_type_id,trim(p_name),
    nullif(trim(coalesce(p_description,'')),''),p_max_seats,
    'site_admin_entry',now(),
    p_min_seats,p_max_seats,p_min_revenue_cents,
    p_min_value_threshold_ratio,p_max_seat_discount_bps,true
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function pace_v2.snapshot_route_offer_discount()
returns trigger
language plpgsql
set search_path = pace_v2, public
as $$
begin
  if tg_op = 'INSERT' or (
    old.commercial_snapshot_locked_at is null
    and old.assigned_seats = 0
    and new.assigned_seats = 0
  ) then
    select vro.post_min_discount_enabled, vro.post_min_discount_bps
      into new.post_min_discount_enabled, new.post_min_discount_bps
    from pace_v2.vehicle_route_offers vro
    where vro.id = new.vehicle_route_offer_id;

    new.commercial_snapshot_source := case
      when tg_op = 'INSERT' then 'route_offer_at_consideration'
      else 'route_offer_refresh'
    end;
  end if;
  return new;
end;
$$;

create or replace function pace_v2.protect_allocated_consideration_snapshot()
returns trigger
language plpgsql
set search_path = pace_v2, public
as $$
declare
  v_is_locked boolean;
begin
  v_is_locked :=
    old.commercial_snapshot_locked_at is not null
    or old.assigned_seats > 0
    or exists (
      select 1 from pace_v2.booking_allocations ba
      where ba.vehicle_consideration_id = old.id
    )
    or exists (
      select 1 from pace_v2.confirmed_allocations ca
      where ca.consideration_id = old.id
    );

  if tg_op = 'DELETE' then
    if v_is_locked then
      raise exception 'Allocated vehicle consideration commercial snapshot cannot be deleted';
    end if;
    return old;
  end if;

  if new.assigned_seats > 0 then v_is_locked := true; end if;

  if v_is_locked and (
    new.vehicle_route_offer_id is distinct from old.vehicle_route_offer_id or
    new.normal_min_seats is distinct from old.normal_min_seats or
    new.max_seats is distinct from old.max_seats or
    new.min_revenue_cents is distinct from old.min_revenue_cents or
    new.min_value_threshold_ratio is distinct from old.min_value_threshold_ratio or
    new.normal_base_seat_price_cents is distinct from old.normal_base_seat_price_cents or
    new.post_min_discount_enabled is distinct from old.post_min_discount_enabled or
    new.post_min_discount_bps is distinct from old.post_min_discount_bps or
    new.commercial_snapshot_source is distinct from old.commercial_snapshot_source or
    new.effective_commission_bps is distinct from old.effective_commission_bps or
    new.effective_commission_source is distinct from old.effective_commission_source
  ) then
    raise exception 'Allocated vehicle consideration commercial snapshot is immutable';
  end if;

  if v_is_locked then
    new.commercial_snapshot_locked_at :=
      coalesce(old.commercial_snapshot_locked_at, now());
  end if;
  return new;
end;
$$;

create or replace view public.v2_vehicles as
select
  id,operator_id,vehicle_type_id,name,description,picture_url,active,
  default_min_seats,default_max_seats,default_min_revenue_cents,
  default_min_value_threshold_ratio,default_max_seat_discount_bps,
  created_at,updated_at,capacity_seats,capacity_source,capacity_verified_at
from pace_v2.vehicles
where pace_v2.is_site_admin();

create or replace view public.v2_operator_my_fleet as
select
  v.id as vehicle_id,v.operator_id,v.vehicle_type_id,
  vt.name as vehicle_type_name,v.name,v.description,v.active,
  v.default_min_seats,v.default_max_seats,v.default_min_revenue_cents,
  v.default_min_value_threshold_ratio,v.default_max_seat_discount_bps,
  v.capacity_seats,v.capacity_source,v.capacity_verified_at
from pace_v2.vehicles v
join pace_v2.vehicle_types vt on vt.id=v.vehicle_type_id
where exists (
  select 1 from pace_v2.operator_memberships om
  where om.operator_id=v.operator_id and om.user_id=auth.uid() and om.active
);

create or replace view public.v2_admin_vehicle_considerations as
select
  vc.id as consideration_id,vc.departure_id,vc.vehicle_route_offer_id,
  vc.vehicle_id,v.name as vehicle_name,vc.operator_id,o.name as operator_name,
  vc.status,vc.normal_min_seats,vc.max_seats,vc.min_revenue_cents,
  vc.min_value_threshold_ratio,vc.normal_base_seat_price_cents,
  vc.assigned_seats,vc.assigned_revenue_cents,vc.minimum_achieved_at,
  vc.discount_activated_at,vc.opened_at,vc.under_consideration_at,
  vc.withdrawal_deadline_ts,vc.withdrawn_at,vc.withdrawal_reason,
  vc.t72_discarded_at,vc.quality_score_snapshot,vc.effective_commission_bps,
  vc.effective_commission_source,vc.engine_version,vc.updated_at,
  vc.post_min_discount_enabled,vc.post_min_discount_bps,
  vc.commercial_snapshot_locked_at,vc.commercial_snapshot_source
from pace_v2.vehicle_considerations vc
join pace_v2.vehicles v on v.id=vc.vehicle_id
join pace_v2.operators o on o.id=vc.operator_id
where pace_v2.is_site_admin();

