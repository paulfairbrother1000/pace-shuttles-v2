-- Selling capacity must be bounded by people as well as vehicles. A captain
-- may be configured as the default for several boats, but can operate only
-- one simultaneous duty. This matcher proves that a selected vehicle set has
-- an injective vehicle-to-captain assignment before that set is offered or
-- retained by either allocation planner.

create or replace function pace_v2.consideration_set_has_distinct_captains(
  p_departure_id uuid,
  p_consideration_ids uuid[]
)
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  with recursive selected as (
    select
      consideration.id as consideration_id,
      vehicle.operator_id,
      vehicle.vehicle_type_id,
      route_offer.preferred_captain_id,
      row_number() over(order by consideration.id)::integer as vehicle_no,
      count(*) over()::integer as vehicle_count
    from pace_v2.vehicle_considerations consideration
    join pace_v2.vehicles vehicle
      on vehicle.id=consideration.vehicle_id
     and vehicle.active
    left join pace_v2.vehicle_route_offers route_offer
      on route_offer.id=consideration.vehicle_route_offer_id
    where consideration.departure_id=p_departure_id
      and consideration.id=any(coalesce(p_consideration_ids,'{}'::uuid[]))
  ), resource as (
    select scheduled_start_ts,scheduled_end_ts,outbound_departure_id
    from pace_v2.captain_duty_resource_window(p_departure_id)
  ), candidate_captains as (
    select distinct
      selected.vehicle_no,
      selected.vehicle_count,
      captain.id as captain_id
    from selected
    cross join resource
    join pace_v2.captains captain
      on captain.operator_id=selected.operator_id
     and captain.active
    join pace_v2.captain_vehicle_types eligibility
      on eligibility.captain_id=captain.id
     and eligibility.vehicle_type_id=selected.vehicle_type_id
     and eligibility.active
    where (
      (selected.preferred_captain_id is not null
       and captain.id=selected.preferred_captain_id)
      or
      (selected.preferred_captain_id is null and exists (
        select 1
        from pace_v2.vehicle_captain_preferences preference
        where preference.vehicle_id=(
          select consideration.vehicle_id
          from pace_v2.vehicle_considerations consideration
          where consideration.id=selected.consideration_id
        )
          and preference.operator_id=selected.operator_id
          and preference.captain_id=captain.id
          and preference.active
      ))
    )
      and not exists (
        select 1
        from pace_v2.captain_assignments assignment
        join pace_v2.confirmed_allocations allocation
          on allocation.id=assignment.confirmed_allocation_id
         and allocation.status='confirmed'
        cross join lateral pace_v2.captain_duty_resource_window(
          allocation.departure_id
        ) other_resource
        where assignment.captain_id=captain.id
          and assignment.active
          and allocation.departure_id<>resource.outbound_departure_id
          and other_resource.scheduled_start_ts<resource.scheduled_end_ts
          and other_resource.scheduled_end_ts>resource.scheduled_start_ts
      )
  ), matching(vehicle_no,vehicle_count,captain_ids) as (
    select
      0,
      coalesce((select max(selected.vehicle_count) from selected),0),
      array[]::uuid[]

    union all

    select
      matching.vehicle_no+1,
      matching.vehicle_count,
      matching.captain_ids||captain.captain_id
    from matching
    join candidate_captains captain
      on captain.vehicle_no=matching.vehicle_no+1
    where captain.captain_id<>all (matching.captain_ids)
  )
  select case
    when coalesce(cardinality(p_consideration_ids),0)=0 then true
    else exists (
      select 1
      from matching
      where matching.vehicle_no=matching.vehicle_count
        and array_length(matching.captain_ids,1)=matching.vehicle_count
    )
  end
$$;

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
set search_path=''
as $$
declare
  d pace_v2.departures%rowtype;
begin
  if p_party_size is null or p_party_size<1 then
    raise exception 'Party size must be at least 1';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_departure_id::text,0));

  select * into d
  from pace_v2.departures
  where id=p_departure_id;

  if not found then
    raise exception 'Departure % not found',p_departure_id;
  end if;

  if now()>=d.t24_ts or d.status in (
    'confirmed','active','completed','cancelled','closed_unrecorded'
  ) then
    return;
  end if;

  perform pace_v2.refresh_vehicle_considerations(
    p_departure_id,
    'live-progressive-v0.8'
  );
  perform pace_v2.refresh_live_consideration_states(p_departure_id);

  if d.t72_ts>now() then
    return query
    with ordered as (
      select
        vc.id as consideration_id,
        vc.vehicle_id,
        vc.operator_id,
        vehicle.name as vehicle_name,
        fleet_operator.name as operator_name,
        vc.normal_min_seats,
        vc.max_seats,
        vc.assigned_seats,
        greatest(
          vc.max_seats-vc.assigned_seats-
          pace_v2.pending_reserved_seats(vc.departure_id,vc.vehicle_id),
          0
        ) as remaining_capacity,
        vc.normal_base_seat_price_cents as normal_price,
        vc.quality_score_snapshot as quality_score,
        vc.post_min_discount_bps as discount_bps,
        row_number() over(
          order by vc.normal_base_seat_price_cents,
                   vc.quality_score_snapshot desc,
                   vc.created_at,
                   vc.id
        )::integer as seq,
        (vc.assigned_seats>=vc.normal_min_seats) as min_met
      from pace_v2.vehicle_considerations vc
      join pace_v2.vehicles vehicle on vehicle.id=vc.vehicle_id
      join pace_v2.operators fleet_operator on fleet_operator.id=vc.operator_id
      where vc.departure_id=p_departure_id
        and vc.status not in(
          'withdrawn','discarded_t72','under_consideration',
          'confirmed','replaced','cancelled'
        )
    ), target as (
      select min(ordered.seq)::integer as target_seq
      from ordered
      where not ordered.min_met
        and ordered.remaining_capacity>=p_party_size
        and pace_v2.consideration_set_has_distinct_captains(
          p_departure_id,
          array(
            select vc.id
            from pace_v2.vehicle_considerations vc
            where vc.departure_id=p_departure_id
              and vc.assigned_seats>0
              and vc.status not in(
                'withdrawn','discarded_t72','confirmed','replaced','cancelled'
              )
            union
            select ordered.consideration_id
          )
        )
    ), candidates as (
      select ordered.*,'PRE_T72_NEXT_MINIMUM'::text as stage
      from ordered cross join target
      where target.target_seq is not null
        and ordered.seq=target.target_seq
        and ordered.remaining_capacity>=p_party_size

      union all

      select ordered.*,'PRE_T72_FULL_PRICE_CAPACITY'::text as stage
      from ordered cross join target
      where target.target_seq is null
        and ordered.min_met
        and ordered.remaining_capacity>=p_party_size
    ), staffable as (
      select candidates.*
      from candidates
      where pace_v2.consideration_set_has_distinct_captains(
        p_departure_id,
        array(
          select vc.id
          from pace_v2.vehicle_considerations vc
          where vc.departure_id=p_departure_id
            and vc.assigned_seats>0
            and vc.status not in(
              'withdrawn','discarded_t72','confirmed','replaced','cancelled'
            )
          union
          select candidates.consideration_id
        )
      )
    ), ranked as (
      select staffable.*,
        row_number() over(
          order by staffable.normal_price,staffable.quality_score desc,
                   staffable.seq,staffable.consideration_id
        )::integer as offer_rank
      from staffable
    )
    select
      ranked.offer_rank,ranked.consideration_id,ranked.vehicle_id,
      ranked.operator_id,ranked.vehicle_name,ranked.operator_name,
      ranked.seq,ranked.stage,ranked.assigned_seats,ranked.remaining_capacity,
      ranked.normal_min_seats,ranked.max_seats,ranked.min_met,
      false,false,ranked.normal_price,ranked.normal_price,
      ranked.discount_bps,ranked.quality_score
    from ranked
    order by ranked.offer_rank;

    return;
  end if;

  return query
  with candidates as (
    select
      vc.id as consideration_id,
      vc.vehicle_id,
      vc.operator_id,
      vehicle.name as vehicle_name,
      fleet_operator.name as operator_name,
      vc.normal_min_seats,
      vc.max_seats,
      vc.assigned_seats,
      greatest(
        vc.max_seats-vc.assigned_seats-
        pace_v2.pending_reserved_seats(vc.departure_id,vc.vehicle_id),
        0
      ) as remaining_capacity,
      vc.normal_base_seat_price_cents as normal_price,
      vc.quality_score_snapshot as quality_score,
      vc.post_min_discount_enabled as discount_enabled,
      vc.post_min_discount_bps as discount_bps,
      row_number() over(
        order by vc.normal_base_seat_price_cents,
                 vc.quality_score_snapshot desc,
                 vc.created_at,
                 vc.id
      )::integer as seq
    from pace_v2.vehicle_considerations vc
    join pace_v2.vehicles vehicle on vehicle.id=vc.vehicle_id
    join pace_v2.operators fleet_operator on fleet_operator.id=vc.operator_id
    where vc.departure_id=p_departure_id
      and vc.status='under_consideration'
      and vc.assigned_seats>=vc.normal_min_seats
  ), priced as (
    select candidates.*,
      candidates.discount_enabled and candidates.discount_bps>0 as use_discount,
      case
        when candidates.discount_enabled and candidates.discount_bps>0
          then ceil(
            candidates.normal_price::numeric*(10000-candidates.discount_bps)/10000
          )::integer
        else candidates.normal_price
      end as offer_price
    from candidates
    where candidates.remaining_capacity>=p_party_size
      and pace_v2.consideration_set_has_distinct_captains(
        p_departure_id,
        array(
          select vc.id
          from pace_v2.vehicle_considerations vc
          where vc.departure_id=p_departure_id
            and vc.status='under_consideration'
            and vc.assigned_seats>0
        )
      )
  ), ranked as (
    select priced.*,
      row_number() over(
        order by priced.offer_price,priced.quality_score desc,
                 priced.seq,priced.consideration_id
      )::integer as offer_rank
    from priced
  )
  select
    ranked.offer_rank,ranked.consideration_id,ranked.vehicle_id,
    ranked.operator_id,ranked.vehicle_name,ranked.operator_name,
    ranked.seq,'POST_T72_DISCOUNT_COMPETITION'::text,
    ranked.assigned_seats,ranked.remaining_capacity,
    ranked.normal_min_seats,ranked.max_seats,
    true,true,ranked.use_discount,ranked.normal_price,ranked.offer_price,
    ranked.discount_bps,ranked.quality_score
  from ranked
  order by ranked.offer_rank;
end;
$$;

create or replace function pace_v2.plan_t72_whole_party_allocations(
  p_departure_id uuid
)
returns table(
  booking_id uuid,
  consideration_id uuid,
  locked_to_discount_vehicle boolean
)
language sql
security definer
set search_path=''
as $$
  with recursive active_bookings as (
    select
      booking.id,
      booking.seats,
      booking.total_price_cents,
      current_allocation.vehicle_consideration_id as current_consideration_id,
      case
        when booking.commercial_snapshot#>>'{quote_snapshot,discount_applied}'='true'
          then coalesce(
            nullif(
              booking.commercial_snapshot#>>'{quote_snapshot,vehicle_consideration_id}',
              ''
            )::uuid,
            current_allocation.vehicle_consideration_id
          )
        else null::uuid
      end as locked_consideration_id
    from pace_v2.bookings booking
    join lateral (
      select allocation.vehicle_consideration_id
      from pace_v2.booking_allocations allocation
      where allocation.booking_id=booking.id
        and allocation.status in ('preliminary','confirmed')
        and allocation.seats=booking.seats
      order by allocation.allocated_at desc,allocation.id
      limit 1
    ) current_allocation on true
    where booking.departure_id=p_departure_id
      and booking.status in ('booked','at_risk','confirmed')
  ), bookings as (
    select active_bookings.*,
      row_number() over(
        order by (active_bookings.locked_consideration_id is not null) desc,
                 active_bookings.seats desc,
                 active_bookings.total_price_cents desc,
                 active_bookings.id
      )::integer as booking_no
    from active_bookings
  ), vehicles as (
    select
      consideration.id,
      consideration.max_seats,
      consideration.normal_min_seats,
      pace_v2.required_consideration_revenue_cents(
        consideration.min_revenue_cents,
        consideration.min_value_threshold_ratio,
        consideration.below_minimum_operation_mode
      ) as required_revenue_cents,
      consideration.quality_score_snapshot,
      consideration.normal_base_seat_price_cents
    from pace_v2.vehicle_considerations consideration
    where consideration.departure_id=p_departure_id
      and consideration.status not in(
        'withdrawn','discarded_t72','confirmed','replaced','cancelled'
      )
  ), limits as (
    select
      (select count(*) from bookings)::integer as booking_count,
      (select count(*) from vehicles)::integer as vehicle_count
  ), search(
    booking_no,seat_totals,revenue_totals,assignments,moved_parties
  ) as (
    select 0,'{}'::jsonb,'{}'::jsonb,array[]::uuid[],0
    from limits
    where booking_count>=1
      and vehicle_count between 1 and 6
      and power(vehicle_count::numeric,booking_count::numeric)<=100000

    union all

    select
      search.booking_no+1,
      search.seat_totals||jsonb_build_object(
        vehicle.id::text,
        coalesce((search.seat_totals->>vehicle.id::text)::integer,0)+booking.seats
      ),
      search.revenue_totals||jsonb_build_object(
        vehicle.id::text,
        coalesce((search.revenue_totals->>vehicle.id::text)::bigint,0)+
          booking.total_price_cents
      ),
      search.assignments||vehicle.id,
      search.moved_parties+
        case when booking.current_consideration_id=vehicle.id then 0 else 1 end
    from search
    join bookings booking on booking.booking_no=search.booking_no+1
    join vehicles vehicle
      on (
        booking.locked_consideration_id is null
        or booking.locked_consideration_id=vehicle.id
      )
     and coalesce((search.seat_totals->>vehicle.id::text)::integer,0)+
           booking.seats<=vehicle.max_seats
  ), valid_plans as (
    select
      search.*,
      (
        select count(*)::integer
        from vehicles vehicle
        where coalesce((search.seat_totals->>vehicle.id::text)::integer,0)>0
      ) as used_vehicle_count,
      (
        select coalesce(sum(vehicle.quality_score_snapshot),0)
        from vehicles vehicle
        where coalesce((search.seat_totals->>vehicle.id::text)::integer,0)>0
      ) as used_quality,
      (
        select coalesce(sum(vehicle.normal_base_seat_price_cents),0)
        from vehicles vehicle
        where coalesce((search.seat_totals->>vehicle.id::text)::integer,0)>0
      ) as used_normal_price
    from search cross join limits
    where search.booking_no=limits.booking_count
      and not exists (
        select 1
        from vehicles vehicle
        where coalesce((search.seat_totals->>vehicle.id::text)::integer,0)>0
          and (
            coalesce((search.seat_totals->>vehicle.id::text)::integer,0)<
              vehicle.normal_min_seats
            or coalesce((search.revenue_totals->>vehicle.id::text)::bigint,0)<
              vehicle.required_revenue_cents
          )
      )
      and pace_v2.consideration_set_has_distinct_captains(
        p_departure_id,
        array(
          select vehicle.id
          from vehicles vehicle
          where coalesce((search.seat_totals->>vehicle.id::text)::integer,0)>0
          order by vehicle.id
        )
      )
  ), winning_plan as (
    select valid_plans.*
    from valid_plans
    order by valid_plans.used_vehicle_count desc,
             valid_plans.moved_parties,
             valid_plans.used_quality desc,
             valid_plans.used_normal_price,
             valid_plans.assignments::text
    limit 1
  )
  select
    booking.id,
    winning_plan.assignments[booking.booking_no],
    booking.locked_consideration_id is not null
  from winning_plan
  join bookings booking on true
  order by booking.booking_no
$$;

create or replace function pace_v2.plan_t24_operator_consolidation(
  p_departure_id uuid,
  p_operator_id uuid
)
returns table(
  booking_id uuid,
  consideration_id uuid,
  locked_to_discount_vehicle boolean,
  existing_vehicle_count integer,
  planned_vehicle_count integer
)
language sql
security definer
set search_path=''
as $$
  with recursive active_bookings as (
    select
      booking.id,
      booking.seats,
      booking.total_price_cents,
      allocation.vehicle_consideration_id as current_consideration_id,
      case
        when booking.commercial_snapshot#>>'{quote_snapshot,discount_applied}'='true'
          then allocation.vehicle_consideration_id
        else null::uuid
      end as locked_consideration_id
    from pace_v2.bookings booking
    join pace_v2.booking_allocations allocation
      on allocation.booking_id=booking.id
     and allocation.status in ('preliminary','confirmed')
     and allocation.seats=booking.seats
    join pace_v2.vehicle_considerations current_vehicle
      on current_vehicle.id=allocation.vehicle_consideration_id
     and current_vehicle.operator_id=p_operator_id
     and current_vehicle.departure_id=p_departure_id
     and current_vehicle.status='under_consideration'
    where booking.departure_id=p_departure_id
      and booking.status in ('booked','at_risk','confirmed')
  ), bookings as (
    select active_bookings.*,
      row_number() over(
        order by (active_bookings.locked_consideration_id is not null) desc,
                 active_bookings.seats desc,
                 active_bookings.total_price_cents desc,
                 active_bookings.id
      )::integer as booking_no
    from active_bookings
  ), vehicles as (
    select
      consideration.id,
      consideration.max_seats,
      consideration.normal_min_seats,
      pace_v2.required_consideration_revenue_cents(
        consideration.min_revenue_cents,
        consideration.min_value_threshold_ratio,
        consideration.below_minimum_operation_mode
      ) as required_revenue_cents,
      consideration.assigned_seats as starting_assigned_seats,
      consideration.quality_score_snapshot
    from pace_v2.vehicle_considerations consideration
    where consideration.departure_id=p_departure_id
      and consideration.operator_id=p_operator_id
      and consideration.status='under_consideration'
      and consideration.assigned_seats>0
  ), limits as (
    select
      (select count(*) from bookings)::integer as booking_count,
      (select count(*) from vehicles)::integer as vehicle_count
  ), search(
    booking_no,seat_totals,revenue_totals,assignments,moved_parties,moved_seats
  ) as (
    select 0,'{}'::jsonb,'{}'::jsonb,array[]::uuid[],0,0
    from limits
    where booking_count>=1
      and vehicle_count between 2 and 6
      and power(vehicle_count::numeric,booking_count::numeric)<=100000

    union all

    select
      search.booking_no+1,
      search.seat_totals||jsonb_build_object(
        vehicle.id::text,
        coalesce((search.seat_totals->>vehicle.id::text)::integer,0)+booking.seats
      ),
      search.revenue_totals||jsonb_build_object(
        vehicle.id::text,
        coalesce((search.revenue_totals->>vehicle.id::text)::bigint,0)+
          booking.total_price_cents
      ),
      search.assignments||vehicle.id,
      search.moved_parties+
        case when booking.current_consideration_id=vehicle.id then 0 else 1 end,
      search.moved_seats+
        case when booking.current_consideration_id=vehicle.id then 0 else booking.seats end
    from search
    join bookings booking on booking.booking_no=search.booking_no+1
    join vehicles vehicle
      on (
        booking.locked_consideration_id is null
        or booking.locked_consideration_id=vehicle.id
      )
     and coalesce((search.seat_totals->>vehicle.id::text)::integer,0)+
           booking.seats<=vehicle.max_seats
  ), valid_plans as (
    select
      search.*,
      (
        select count(*)::integer
        from vehicles vehicle
        where coalesce((search.seat_totals->>vehicle.id::text)::integer,0)>0
      ) as used_vehicle_count,
      (
        select coalesce(sum(vehicle.max_seats),0)
        from vehicles vehicle
        where coalesce((search.seat_totals->>vehicle.id::text)::integer,0)>0
      ) as retained_capacity,
      (
        select coalesce(sum(vehicle.quality_score_snapshot),0)
        from vehicles vehicle
        where coalesce((search.seat_totals->>vehicle.id::text)::integer,0)>0
      ) as retained_quality
    from search cross join limits
    where search.booking_no=limits.booking_count
      and not exists (
        select 1
        from vehicles vehicle
        where coalesce((search.seat_totals->>vehicle.id::text)::integer,0)>0
          and (
            coalesce((search.seat_totals->>vehicle.id::text)::integer,0)<
              vehicle.normal_min_seats
            or coalesce((search.revenue_totals->>vehicle.id::text)::bigint,0)<
              vehicle.required_revenue_cents
          )
      )
      and pace_v2.consideration_set_has_distinct_captains(
        p_departure_id,
        array(
          select vehicle.id
          from vehicles vehicle
          where coalesce((search.seat_totals->>vehicle.id::text)::integer,0)>0
          order by vehicle.id
        )
      )
  ), winning_plan as (
    select valid_plans.*,limits.vehicle_count
    from valid_plans cross join limits
    where valid_plans.used_vehicle_count<limits.vehicle_count
    order by valid_plans.used_vehicle_count,
             valid_plans.moved_seats,
             valid_plans.moved_parties,
             valid_plans.retained_capacity desc,
             valid_plans.retained_quality desc,
             valid_plans.assignments::text
    limit 1
  )
  select
    booking.id,
    winning_plan.assignments[booking.booking_no],
    booking.locked_consideration_id is not null,
    winning_plan.vehicle_count,
    winning_plan.used_vehicle_count
  from winning_plan
  join bookings booking on true
  order by booking.booking_no
$$;

comment on function pace_v2.consideration_set_has_distinct_captains(uuid,uuid[]) is
  'Returns true only when every simultaneous vehicle can be matched to a different configured, eligible and conflict-free captain.';

revoke all on function
  pace_v2.consideration_set_has_distinct_captains(uuid,uuid[]),
  pace_v2.get_live_party_offer_candidates(uuid,integer),
  pace_v2.plan_t72_whole_party_allocations(uuid),
  pace_v2.plan_t24_operator_consolidation(uuid,uuid)
from public,anon,authenticated,service_role;
