-- Captain coverage is a prerequisite for activating operators and vehicles.
-- Deferred triggers allow the vehicle editor to save the vehicle and its
-- default captain atomically before the invariant is checked.

create or replace function pace_v2.assert_active_operator_has_captain(p_operator_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_active boolean;
begin
  select operator.active into v_active
  from pace_v2.operators operator
  where operator.id = p_operator_id;

  if not found or not v_active then
    return;
  end if;

  if not exists (
    select 1
    from pace_v2.captains captain
    where captain.operator_id = p_operator_id
      and captain.active
  ) then
    raise exception 'operator requires at least one active captain';
  end if;
end;
$$;

create or replace function pace_v2.validate_active_operator_captain()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op <> 'DELETE' then
    perform pace_v2.assert_active_operator_has_captain(new.id);
    return new;
  end if;
  return old;
end;
$$;

create or replace function pace_v2.validate_operator_captain_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op <> 'INSERT' then
    perform pace_v2.assert_active_operator_has_captain(old.operator_id);
  end if;
  if tg_op <> 'DELETE'
     and (tg_op = 'INSERT' or new.operator_id is distinct from old.operator_id) then
    perform pace_v2.assert_active_operator_has_captain(new.operator_id);
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists operators_require_active_captain on pace_v2.operators;
create constraint trigger operators_require_active_captain
after insert or update on pace_v2.operators
deferrable initially deferred
for each row execute function pace_v2.validate_active_operator_captain();

drop trigger if exists captains_preserve_active_operator_coverage on pace_v2.captains;
create constraint trigger captains_preserve_active_operator_coverage
after insert or update or delete on pace_v2.captains
deferrable initially deferred
for each row execute function pace_v2.validate_operator_captain_change();

create or replace function pace_v2.assert_active_vehicle_has_eligible_captain(p_vehicle_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_active boolean;
  v_operator_id uuid;
  v_vehicle_type_id uuid;
begin
  select vehicle.active, vehicle.operator_id, vehicle.vehicle_type_id
    into v_active, v_operator_id, v_vehicle_type_id
  from pace_v2.vehicles vehicle
  where vehicle.id = p_vehicle_id;

  if not found or not v_active then
    return;
  end if;

  if not exists (
    select 1
    from pace_v2.vehicle_captain_preferences preference
    join pace_v2.captains captain
      on captain.id = preference.captain_id
     and captain.operator_id = v_operator_id
     and captain.active
    join pace_v2.captain_vehicle_types eligibility
      on eligibility.captain_id = captain.id
     and eligibility.vehicle_type_id = v_vehicle_type_id
     and eligibility.active
    where preference.vehicle_id = p_vehicle_id
      and preference.operator_id = v_operator_id
      and preference.active
  ) then
    raise exception 'vehicle requires an active eligible default captain';
  end if;
end;
$$;

create or replace function pace_v2.validate_active_vehicle_captain()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op <> 'DELETE' then
    perform pace_v2.assert_active_vehicle_has_eligible_captain(new.id);
    return new;
  end if;
  return old;
end;
$$;

create or replace function pace_v2.validate_vehicle_preference_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op <> 'INSERT' then
    perform pace_v2.assert_active_vehicle_has_eligible_captain(old.vehicle_id);
  end if;
  if tg_op <> 'DELETE'
     and (tg_op = 'INSERT' or new.vehicle_id is distinct from old.vehicle_id) then
    perform pace_v2.assert_active_vehicle_has_eligible_captain(new.vehicle_id);
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create or replace function pace_v2.validate_captain_vehicle_coverage_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_captain_id uuid;
  v_vehicle_id uuid;
begin
  if tg_op <> 'INSERT' then
    v_captain_id := old.captain_id;
    for v_vehicle_id in
      select distinct preference.vehicle_id
      from pace_v2.vehicle_captain_preferences preference
      where preference.captain_id = v_captain_id
    loop
      perform pace_v2.assert_active_vehicle_has_eligible_captain(v_vehicle_id);
    end loop;
  end if;

  if tg_op <> 'DELETE'
     and (tg_op = 'INSERT' or new.captain_id is distinct from old.captain_id) then
    v_captain_id := new.captain_id;
    for v_vehicle_id in
      select distinct preference.vehicle_id
      from pace_v2.vehicle_captain_preferences preference
      where preference.captain_id = v_captain_id
    loop
      perform pace_v2.assert_active_vehicle_has_eligible_captain(v_vehicle_id);
    end loop;
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create or replace function pace_v2.validate_captain_vehicle_defaults_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_vehicle_id uuid;
  v_captain_id uuid;
begin
  if tg_op = 'DELETE' then v_captain_id := old.id; else v_captain_id := new.id; end if;
  for v_vehicle_id in
    select distinct preference.vehicle_id
    from pace_v2.vehicle_captain_preferences preference
    where preference.captain_id = v_captain_id
  loop
    perform pace_v2.assert_active_vehicle_has_eligible_captain(v_vehicle_id);
  end loop;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists vehicles_require_eligible_default_captain on pace_v2.vehicles;
create constraint trigger vehicles_require_eligible_default_captain
after insert or update on pace_v2.vehicles
deferrable initially deferred
for each row execute function pace_v2.validate_active_vehicle_captain();

drop trigger if exists vehicle_preferences_preserve_captain_coverage on pace_v2.vehicle_captain_preferences;
create constraint trigger vehicle_preferences_preserve_captain_coverage
after insert or update or delete on pace_v2.vehicle_captain_preferences
deferrable initially deferred
for each row execute function pace_v2.validate_vehicle_preference_change();

drop trigger if exists captain_vehicle_types_preserve_vehicle_defaults on pace_v2.captain_vehicle_types;
create constraint trigger captain_vehicle_types_preserve_vehicle_defaults
after insert or update or delete on pace_v2.captain_vehicle_types
deferrable initially deferred
for each row execute function pace_v2.validate_captain_vehicle_coverage_change();

drop trigger if exists captains_preserve_vehicle_defaults on pace_v2.captains;
create constraint trigger captains_preserve_vehicle_defaults
after insert or update or delete on pace_v2.captains
deferrable initially deferred
for each row execute function pace_v2.validate_captain_vehicle_defaults_change();

-- Only explicitly configured captains are eligible. A route override takes
-- precedence; otherwise the vehicle's active default preference is used.
create or replace function pace_v2.get_eligible_vehicle_offers(p_departure_id uuid)
returns table(
  departure_id uuid, route_id uuid, vehicle_route_offer_id uuid,
  vehicle_id uuid, operator_id uuid, vehicle_type_id uuid,
  normal_min_seats integer, max_seats integer, min_revenue_cents integer,
  min_value_threshold_ratio numeric, normal_base_seat_price_cents integer,
  quality_score numeric, effective_commission_bps integer,
  effective_commission_source text
)
language sql stable security definer set search_path = '' as $eligibility$
  with candidate as (
    select departure.id as departure_id, departure.route_id, route.country_id,
      resource.scheduled_start_ts, resource.scheduled_end_ts,
      offer.id as vehicle_route_offer_id, vehicle.id as vehicle_id,
      vehicle.operator_id, vehicle.vehicle_type_id, offer.min_seats,
      offer.max_seats, offer.min_revenue_cents, offer.min_value_threshold_ratio,
      ceil(offer.min_revenue_cents::numeric / offer.min_seats)::integer as base_seat_price,
      fleet_operator.quality_score
    from pace_v2.departures departure
    join pace_v2.routes route on route.id = departure.route_id
    cross join lateral pace_v2.captain_duty_resource_window(departure.id) resource
    join pace_v2.vehicle_route_offers offer
      on offer.service_id = departure.service_id and offer.active
     and offer.effective_from <= resource.scheduled_start_ts
     and (offer.effective_to is null or offer.effective_to > resource.scheduled_start_ts)
    join pace_v2.vehicles vehicle on vehicle.id = offer.vehicle_id and vehicle.active
    join pace_v2.operators fleet_operator
      on fleet_operator.id = vehicle.operator_id and fleet_operator.active
    join pace_v2.operator_vehicle_types operator_type
      on operator_type.operator_id = vehicle.operator_id
     and operator_type.vehicle_type_id = vehicle.vehicle_type_id
     and operator_type.status = 'approved'
    join pace_v2.route_vehicle_types outbound_route_eligibility
      on outbound_route_eligibility.route_id = resource.outbound_route_id
     and outbound_route_eligibility.vehicle_type_id = vehicle.vehicle_type_id
     and outbound_route_eligibility.active
     and outbound_route_eligibility.effective_from <= resource.scheduled_start_ts
     and (outbound_route_eligibility.effective_to is null
       or outbound_route_eligibility.effective_to > resource.scheduled_start_ts)
    join pace_v2.route_vehicle_types return_route_eligibility
      on return_route_eligibility.route_id = resource.final_route_id
     and return_route_eligibility.vehicle_type_id = vehicle.vehicle_type_id
     and return_route_eligibility.active
     and return_route_eligibility.effective_from <= resource.final_scheduled_departure_ts
     and (return_route_eligibility.effective_to is null
       or return_route_eligibility.effective_to > resource.final_scheduled_departure_ts)
    where departure.id = p_departure_id
      and departure.status not in ('cancelled', 'completed')
      and not exists (
        select 1 from pace_v2.vehicle_availability_exceptions availability
        where availability.vehicle_id = vehicle.id
          and availability.start_ts < resource.scheduled_end_ts
          and availability.end_ts > resource.scheduled_start_ts
      )
      and not exists (
        select 1
        from pace_v2.confirmed_allocations other_allocation
        cross join lateral pace_v2.captain_duty_resource_window(other_allocation.departure_id) other_resource
        where other_allocation.vehicle_id = vehicle.id
          and other_allocation.status = 'confirmed'
          and other_allocation.departure_id <> resource.outbound_departure_id
          and other_resource.scheduled_start_ts < resource.scheduled_end_ts
          and other_resource.scheduled_end_ts > resource.scheduled_start_ts
      )
      and exists (
        select 1
        from pace_v2.captains captain
        join pace_v2.captain_vehicle_types captain_type
          on captain_type.captain_id = captain.id
         and captain_type.vehicle_type_id = vehicle.vehicle_type_id
         and captain_type.active
        where captain.operator_id = vehicle.operator_id
          and captain.active
          and (
            (offer.preferred_captain_id is not null
              and captain.id = offer.preferred_captain_id)
            or
            (offer.preferred_captain_id is null and exists (
              select 1
              from pace_v2.vehicle_captain_preferences preference
              where preference.vehicle_id = vehicle.id
                and preference.operator_id = vehicle.operator_id
                and preference.captain_id = captain.id
                and preference.active
            ))
          )
          and not exists (
            select 1
            from pace_v2.captain_assignments other_assignment
            join pace_v2.confirmed_allocations other_allocation
              on other_allocation.id = other_assignment.confirmed_allocation_id
             and other_allocation.status = 'confirmed'
            cross join lateral pace_v2.captain_duty_resource_window(other_allocation.departure_id) other_resource
            where other_assignment.captain_id = captain.id
              and other_assignment.active
              and other_allocation.departure_id <> resource.outbound_departure_id
              and other_resource.scheduled_start_ts < resource.scheduled_end_ts
              and other_resource.scheduled_end_ts > resource.scheduled_start_ts
          )
      )
  )
  select candidate.departure_id, candidate.route_id, candidate.vehicle_route_offer_id,
    candidate.vehicle_id, candidate.operator_id, candidate.vehicle_type_id,
    candidate.min_seats, candidate.max_seats, candidate.min_revenue_cents,
    candidate.min_value_threshold_ratio, candidate.base_seat_price,
    candidate.quality_score, commission.commission_bps, commission.commission_source
  from candidate
  left join lateral pace_v2.get_effective_commission(
    candidate.operator_id, candidate.country_id, candidate.scheduled_start_ts
  ) commission on true
$eligibility$;

create or replace function pace_v2.pick_default_captain(p_confirmed_allocation_id uuid)
returns table(captain_id uuid, priority integer)
language sql stable security definer set search_path = '' as $$
  with target as (
    select allocation.id as confirmed_allocation_id, allocation.vehicle_id,
      allocation.operator_id, vehicle.vehicle_type_id,
      resource.scheduled_start_ts, resource.scheduled_end_ts,
      route_offer.preferred_captain_id as route_captain_id
    from pace_v2.confirmed_allocations allocation
    join pace_v2.vehicles vehicle on vehicle.id = allocation.vehicle_id
    cross join lateral pace_v2.captain_duty_resource_window(allocation.departure_id) resource
    left join pace_v2.vehicle_considerations consideration
      on consideration.id = allocation.consideration_id
    left join pace_v2.vehicle_route_offers route_offer
      on route_offer.id = consideration.vehicle_route_offer_id
    where allocation.id = p_confirmed_allocation_id
  ), preferences as (
    select target.route_captain_id as captain_id, 0 as priority
    from target
    where target.route_captain_id is not null
    union all
    select preference.captain_id, 100 + preference.priority
    from target
    join pace_v2.vehicle_captain_preferences preference
      on preference.vehicle_id = target.vehicle_id
     and preference.operator_id = target.operator_id
     and preference.active
    where target.route_captain_id is null
  ), ranked as (
    select preferences.captain_id, min(preferences.priority)::integer as priority
    from preferences
    group by preferences.captain_id
  )
  select ranked.captain_id, ranked.priority
  from ranked
  join target on true
  join pace_v2.captains captain
    on captain.id = ranked.captain_id
   and captain.operator_id = target.operator_id
   and captain.active
  join pace_v2.captain_vehicle_types eligibility
    on eligibility.captain_id = captain.id
   and eligibility.vehicle_type_id = target.vehicle_type_id
   and eligibility.active
  where not exists (
    select 1
    from pace_v2.captain_assignments other_assignment
    join pace_v2.confirmed_allocations other_allocation
      on other_allocation.id = other_assignment.confirmed_allocation_id
    cross join lateral pace_v2.captain_duty_resource_window(other_allocation.departure_id) other_resource
    where other_assignment.captain_id = captain.id
      and other_assignment.active
      and other_allocation.status = 'confirmed'
      and other_allocation.id <> p_confirmed_allocation_id
      and other_resource.scheduled_start_ts < target.scheduled_end_ts
      and other_resource.scheduled_end_ts > target.scheduled_start_ts
  )
  order by ranked.priority, ranked.captain_id
  limit 1
$$;

revoke all on function pace_v2.assert_active_operator_has_captain(uuid),
  pace_v2.validate_active_operator_captain(),
  pace_v2.validate_operator_captain_change(),
  pace_v2.assert_active_vehicle_has_eligible_captain(uuid),
  pace_v2.validate_active_vehicle_captain(),
  pace_v2.validate_vehicle_preference_change(),
  pace_v2.validate_captain_vehicle_coverage_change(),
  pace_v2.validate_captain_vehicle_defaults_change(),
  pace_v2.get_eligible_vehicle_offers(uuid),
  pace_v2.pick_default_captain(uuid)
from public, anon, authenticated;
