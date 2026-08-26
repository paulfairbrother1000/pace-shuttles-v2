-- Re-apply Route Offer validation with a vehicle-row lock so concurrent
-- offer writes and capacity changes cannot both commit an invalid state.
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
  for update;

  if v_operator_id is null then
    raise exception 'Vehicle % does not exist', new.vehicle_id;
  end if;
  if new.max_seats > v_capacity_seats then
    raise exception 'Route Offer maximum seats % exceed vehicle capacity %',
      new.max_seats, v_capacity_seats;
  end if;
  if not new.active then return new; end if;
  if not exists (
    select 1 from pace_v2.vehicles
    where id = new.vehicle_id and active = true
  ) then
    raise exception 'Vehicle % is inactive', new.vehicle_id;
  end if;

  select exists (
    select 1 from pace_v2.operator_vehicle_types ovt
    where ovt.operator_id = v_operator_id
      and ovt.vehicle_type_id = v_vehicle_type_id
      and ovt.status = 'approved'
  ) into v_ok;
  if not v_ok then
    raise exception 'Operator is not approved for vehicle type %', v_vehicle_type_id;
  end if;

  select exists (
    select 1 from pace_v2.route_vehicle_types rvt
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

alter table pace_v2.vehicle_considerations
  add column if not exists post_min_discount_enabled boolean,
  add column if not exists post_min_discount_bps integer,
  add column if not exists commercial_snapshot_locked_at timestamptz;

update pace_v2.vehicle_considerations vc
set
  post_min_discount_enabled = vro.post_min_discount_enabled,
  post_min_discount_bps = vro.post_min_discount_bps,
  commercial_snapshot_locked_at = case
    when vc.assigned_seats > 0
      or exists (
        select 1 from pace_v2.booking_allocations ba
        where ba.vehicle_consideration_id = vc.id
      )
      or exists (
        select 1 from pace_v2.confirmed_allocations ca
        where ca.consideration_id = vc.id
      )
    then coalesce(vc.commercial_snapshot_locked_at, now())
    else vc.commercial_snapshot_locked_at
  end
from pace_v2.vehicle_route_offers vro
where vro.id = vc.vehicle_route_offer_id;

alter table pace_v2.vehicle_considerations
  alter column post_min_discount_enabled set default false,
  alter column post_min_discount_enabled set not null,
  alter column post_min_discount_bps set default 0,
  alter column post_min_discount_bps set not null;

alter table pace_v2.vehicle_considerations
  drop constraint if exists consideration_discount_check;

alter table pace_v2.vehicle_considerations
  add constraint consideration_discount_check
  check (post_min_discount_bps between 0 and 10000);

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
  end if;

  return new;
end;
$$;

drop trigger if exists trg_snapshot_route_offer_discount
  on pace_v2.vehicle_considerations;

create trigger trg_snapshot_route_offer_discount
before insert or update on pace_v2.vehicle_considerations
for each row execute function pace_v2.snapshot_route_offer_discount();

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

  if new.assigned_seats > 0 then
    v_is_locked := true;
  end if;

  if v_is_locked and (
    new.vehicle_route_offer_id is distinct from old.vehicle_route_offer_id or
    new.normal_min_seats is distinct from old.normal_min_seats or
    new.max_seats is distinct from old.max_seats or
    new.min_revenue_cents is distinct from old.min_revenue_cents or
    new.min_value_threshold_ratio is distinct from old.min_value_threshold_ratio or
    new.normal_base_seat_price_cents is distinct from old.normal_base_seat_price_cents or
    new.post_min_discount_enabled is distinct from old.post_min_discount_enabled or
    new.post_min_discount_bps is distinct from old.post_min_discount_bps or
    new.effective_commission_bps is distinct from old.effective_commission_bps or
    new.effective_commission_source is distinct from old.effective_commission_source
  ) then
    raise exception 'Allocated vehicle consideration commercial snapshot is immutable';
  end if;

  if v_is_locked then
    new.commercial_snapshot_locked_at :=
      coalesce(old.commercial_snapshot_locked_at, now());
  elsif old.commercial_snapshot_locked_at is not null
    and new.commercial_snapshot_locked_at is null then
    new.commercial_snapshot_locked_at := old.commercial_snapshot_locked_at;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_protect_allocated_consideration_snapshot
  on pace_v2.vehicle_considerations;

create trigger trg_protect_allocated_consideration_snapshot
before update or delete on pace_v2.vehicle_considerations
for each row execute function pace_v2.protect_allocated_consideration_snapshot();

create or replace function pace_v2.get_live_party_offer_candidates(
  p_departure_id uuid,
  p_party_size integer
)
returns table(
  candidate_rank integer,
  vehicle_consideration_id uuid,
  vehicle_id uuid,
  operator_id uuid,
  vehicle_name text,
  operator_name text,
  sequence_no integer,
  allocation_stage text,
  assigned_seats integer,
  remaining_capacity integer,
  normal_min_seats integer,
  max_seats integer,
  minimum_achieved boolean,
  discount_unlocked boolean,
  discount_applied boolean,
  normal_price_cents integer,
  offered_price_cents integer,
  post_min_discount_bps integer,
  quality_score numeric
)
language plpgsql
security definer
set search_path = pace_v2, public
as $$
begin
  if p_party_size is null or p_party_size < 1 then
    raise exception 'Party size must be at least 1';
  end if;

  perform pace_v2.refresh_vehicle_considerations(
    p_departure_id,
    'live-progressive-v0.5'
  );
  perform pace_v2.refresh_live_consideration_states(p_departure_id);

  return query
  with ordered as (
    select
      vc.id as consideration_id,
      vc.vehicle_id,
      vc.operator_id,
      v.name as vehicle_name,
      o.name as operator_name,
      vc.normal_min_seats,
      vc.max_seats,
      vc.assigned_seats,
      greatest(vc.max_seats - vc.assigned_seats, 0) as remaining_capacity,
      vc.normal_base_seat_price_cents as normal_price,
      vc.quality_score_snapshot as quality_score,
      vc.post_min_discount_enabled as discount_enabled,
      vc.post_min_discount_bps as discount_bps,
      row_number() over (
        order by vc.normal_base_seat_price_cents asc,
          vc.quality_score_snapshot desc, vc.created_at asc, vc.id asc
      )::integer as seq,
      (vc.assigned_seats >= vc.normal_min_seats) as min_met
    from pace_v2.vehicle_considerations vc
    join pace_v2.vehicles v on v.id = vc.vehicle_id
    join pace_v2.operators o on o.id = vc.operator_id
    where vc.departure_id = p_departure_id
      and vc.status not in (
        'withdrawn','discarded_t72','under_consideration',
        'confirmed','replaced','cancelled'
      )
  ),
  state as (
    select
      coalesce(count(*) filter (where min_met),0)::integer as min_met_count,
      coalesce(min(seq) filter (where not min_met),2147483647)::integer as frontier_seq
    from ordered
  ),
  target as (
    select min(o.seq)::integer as normal_target_seq
    from ordered o, state s
    where not o.min_met
      and o.seq >= s.frontier_seq
      and o.remaining_capacity >= p_party_size
  ),
  raw_candidates as (
    select o.*,
      case
        when s.min_met_count = 0 then 'FILL_VEHICLE_1_MINIMUM'
        when s.min_met_count = 1 then 'FILL_VEHICLE_2_MINIMUM'
        else 'NEXT_VEHICLE_NORMAL_MINIMUM'
      end::text as stage,
      false as use_discount,
      o.normal_price as offer_price
    from ordered o
    cross join state s
    cross join target t
    where t.normal_target_seq is not null
      and o.seq = t.normal_target_seq
      and o.remaining_capacity >= p_party_size

    union all

    select o.*,
      'POST_TWO_MINIMUMS_COMPETITION'::text as stage,
      (o.discount_enabled and o.discount_bps > 0) as use_discount,
      case when o.discount_enabled and o.discount_bps > 0
        then ceil(o.normal_price::numeric * (10000-o.discount_bps)::numeric / 10000)::integer
        else o.normal_price
      end as offer_price
    from ordered o
    cross join state s
    where s.min_met_count >= 2
      and o.min_met
      and o.remaining_capacity >= p_party_size
  ),
  deduped as (
    select distinct on (rc.consideration_id) rc.*
    from raw_candidates rc
    order by rc.consideration_id, rc.offer_price, rc.use_discount desc
  ),
  ranked as (
    select d.*,
      row_number() over (
        order by d.offer_price asc, d.quality_score desc,
          d.seq asc, d.consideration_id asc
      )::integer as offer_rank
    from deduped d
  )
  select
    r.offer_rank, r.consideration_id, r.vehicle_id, r.operator_id,
    r.vehicle_name, r.operator_name, r.seq, r.stage, r.assigned_seats,
    r.remaining_capacity, r.normal_min_seats, r.max_seats, r.min_met,
    ((select min_met_count from state) >= 2), r.use_discount,
    r.normal_price, r.offer_price, r.discount_bps, r.quality_score
  from ranked r
  order by r.offer_rank;
end;
$$;
