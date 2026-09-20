create extension if not exists btree_gist with schema extensions;

create table pace_v2.captain_duty_reservations(
  id uuid primary key default gen_random_uuid(),
  departure_id uuid not null references pace_v2.departures(id),
  vehicle_consideration_id uuid not null references pace_v2.vehicle_considerations(id),
  operator_id uuid not null references pace_v2.operators(id),
  vehicle_id uuid not null references pace_v2.vehicles(id),
  captain_id uuid not null references pace_v2.captains(id),
  duty_start_ts timestamptz not null,
  duty_end_ts timestamptz not null,
  duty_window tstzrange generated always as
    (tstzrange(duty_start_ts,duty_end_ts,'[)')) stored,
  state text not null check(state in('provisional','held_t72','confirmed_t24','released')),
  confirmed_allocation_id uuid references pace_v2.confirmed_allocations(id),
  captain_assignment_id uuid references pace_v2.captain_assignments(id),
  source text not null,
  engine_version text not null,
  created_at timestamptz not null default now(),
  promoted_at timestamptz,
  released_at timestamptz,
  release_reason text,
  check(duty_end_ts>duty_start_ts),
  check((state='released')=(released_at is not null))
);

alter table pace_v2.captain_duty_reservations
  add constraint captain_duty_reservations_no_overlap
  exclude using gist(captain_id with =,duty_window with &&)
  where(state in('provisional','held_t72','confirmed_t24'))
  deferrable initially immediate;

create unique index captain_duty_reservations_one_active_consideration
  on pace_v2.captain_duty_reservations(vehicle_consideration_id)
  where state in('provisional','held_t72','confirmed_t24');

create index captain_duty_reservations_departure_state_idx
  on pace_v2.captain_duty_reservations(departure_id,state);

alter table pace_v2.captain_duty_reservations enable row level security;

revoke all on pace_v2.captain_duty_reservations from public,anon,authenticated;

-- A captain remains occupied for the complete paired duty and the
-- operational 30-minute allowance after the final scheduled arrival.
create or replace function pace_v2.captain_duty_resource_window(p_departure_id uuid)
returns table(
  outbound_departure_id uuid,
  final_departure_id uuid,
  scheduled_start_ts timestamptz,
  scheduled_end_ts timestamptz,
  outbound_route_id uuid,
  final_route_id uuid,
  final_scheduled_departure_ts timestamptz
)
language sql stable security definer set search_path='' as $$
  select
    outbound.id,
    coalesce(pair.return_departure_id,outbound.id),
    outbound.scheduled_departure_ts,
    coalesce(return_leg.scheduled_arrival_ts,outbound.scheduled_arrival_ts,
      outbound.scheduled_departure_ts+interval '8 hours')+interval '30 minutes',
    outbound.route_id,
    coalesce(return_leg.route_id,outbound.route_id),
    coalesce(return_leg.scheduled_departure_ts,outbound.scheduled_departure_ts)
  from pace_v2.departures requested
  left join pace_v2.journey_pairs pair on pair.id=requested.journey_pair_id
  join pace_v2.departures outbound
    on outbound.id=coalesce(pair.outbound_departure_id,requested.id)
  left join pace_v2.departures return_leg
    on return_leg.id=pair.return_departure_id
  where requested.id=p_departure_id
$$;

create or replace function pace_v2.captain_reservation_window(p_departure_id uuid)
returns tstzrange
language sql stable security definer set search_path='' as $$
  select tstzrange(
    resource.scheduled_start_ts,
    resource.scheduled_end_ts,
    '[)'
  )
  from pace_v2.captain_duty_resource_window(p_departure_id) resource
$$;

revoke all on function pace_v2.captain_duty_resource_window(uuid)
  from public,anon,authenticated;
revoke all on function pace_v2.captain_reservation_window(uuid)
  from public,anon,authenticated;

create or replace function pace_v2.captain_candidates_for_consideration(
  p_consideration_id uuid
)
returns table(captain_id uuid,priority integer)
language sql stable security definer set search_path='' as $$
  with target as (
    select
      consideration.id as consideration_id,
      consideration.departure_id,
      consideration.vehicle_id,
      consideration.operator_id,
      vehicle.vehicle_type_id,
      route_offer.preferred_captain_id
    from pace_v2.vehicle_considerations consideration
    join pace_v2.vehicles vehicle
      on vehicle.id=consideration.vehicle_id
     and vehicle.active
    left join pace_v2.vehicle_route_offers route_offer
      on route_offer.id=consideration.vehicle_route_offer_id
    where consideration.id=p_consideration_id
  ), resource as (
    select
      duty.outbound_departure_id,
      duty.scheduled_start_ts,
      duty.scheduled_end_ts
    from target
    cross join lateral pace_v2.captain_duty_resource_window(
      target.departure_id
    ) duty
  )
  select
    captain.id,
    case
      when target.preferred_captain_id=captain.id then 0
      else 100
        +coalesce(preference.priority,9999)
    end::integer
  from target
  cross join resource
  join pace_v2.captains captain
    on captain.operator_id=target.operator_id
   and captain.active
  join pace_v2.captain_vehicle_types eligibility
    on eligibility.captain_id=captain.id
   and eligibility.vehicle_type_id=target.vehicle_type_id
   and eligibility.active
  left join pace_v2.vehicle_captain_preferences preference
    on preference.vehicle_id=target.vehicle_id
   and preference.operator_id=target.operator_id
   and preference.captain_id=captain.id
   and preference.active
  where (
    (target.preferred_captain_id is not null
     and captain.id=target.preferred_captain_id)
    or
    (target.preferred_captain_id is null and preference.captain_id is not null)
  )
    and not exists (
      select 1
      from pace_v2.captain_duty_reservations reservation
      where reservation.captain_id=captain.id
        and reservation.state in('provisional','held_t72','confirmed_t24')
        and reservation.vehicle_consideration_id<>target.consideration_id
        and reservation.duty_window && tstzrange(
          resource.scheduled_start_ts,resource.scheduled_end_ts,'[)'
        )
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
  order by 2,captain.id
$$;

revoke all on function pace_v2.captain_candidates_for_consideration(uuid)
  from public,anon,authenticated,service_role;

create or replace function pace_v2.consideration_set_has_distinct_captains(
  p_departure_id uuid,
  p_consideration_ids uuid[]
)
returns boolean
language sql stable security definer set search_path='' as $$
  with recursive selected as (
    select
      consideration.id,
      row_number() over(order by consideration.id)::integer as item_no,
      count(*) over()::integer as item_count
    from pace_v2.vehicle_considerations consideration
    where consideration.departure_id=p_departure_id
      and consideration.id=any(coalesce(p_consideration_ids,'{}'::uuid[]))
  ), matching(item_no,item_count,captain_ids) as (
    select
      0,
      coalesce((select max(selected.item_count) from selected),0),
      array[]::uuid[]
    union all
    select
      matching.item_no+1,
      matching.item_count,
      matching.captain_ids||candidate.captain_id
    from matching
    join selected
      on selected.item_no=matching.item_no+1
    cross join lateral pace_v2.captain_candidates_for_consideration(
      selected.id
    ) candidate
    where candidate.captain_id<>all(matching.captain_ids)
  )
  select case
    when coalesce(cardinality(p_consideration_ids),0)=0 then true
    when (select count(*) from selected)
         <> (select count(distinct requested.id) from unnest(p_consideration_ids) requested(id))
      then false
    else exists (
      select 1
      from matching
      where matching.item_no=matching.item_count
        and cardinality(matching.captain_ids)=matching.item_count
    )
  end
$$;

create or replace function pace_v2.reconcile_departure_captain_reservations(
  p_departure_id uuid,
  p_target_state text,
  p_source text
)
returns table(
  outcome text,
  reserved_count integer,
  unreserved_consideration_ids uuid[]
)
language plpgsql security definer set search_path='' as $$
declare
  demanded_ids uuid[];
  matched_consideration_ids uuid[];
  matched_captain_ids uuid[];
  unmatched_consideration_ids uuid[];
  demanded_count integer;
  matched_count integer;
  item_index integer;
  current_consideration pace_v2.vehicle_considerations%rowtype;
  current_resource record;
  existing_reservation pace_v2.captain_duty_reservations%rowtype;
  selected_state text;
  lock_candidate record;
  attempt integer;
begin
  if p_target_state not in('provisional','held_t72') then
    raise exception 'unsupported captain reservation target state: %',p_target_state;
  end if;
  if nullif(btrim(p_source),'') is null then
    raise exception 'captain reservation source is required';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_departure_id::text,0));
  if not exists(select 1 from pace_v2.departures where id=p_departure_id) then
    raise exception 'Departure % not found',p_departure_id;
  end if;

  for attempt in 1..2 loop
    begin
      select coalesce(array_agg(consideration.id order by
        case coalesce(reservation.state,'')
          when 'confirmed_t24' then 0
          when 'held_t72' then 1
          when 'provisional' then 2
          else 3
        end,
        consideration.id
      ),'{}'::uuid[])
      into demanded_ids
      from pace_v2.vehicle_considerations consideration
      left join pace_v2.captain_duty_reservations reservation
        on reservation.vehicle_consideration_id=consideration.id
       and reservation.state in('provisional','held_t72','confirmed_t24')
      where consideration.departure_id=p_departure_id
        and consideration.assigned_seats>0
        and consideration.status not in(
          'withdrawn','discarded_t72','replaced','cancelled'
        );

      demanded_count:=cardinality(demanded_ids);

      for lock_candidate in
        select distinct candidate.captain_id
        from unnest(demanded_ids) demanded(consideration_id)
        cross join lateral pace_v2.captain_candidates_for_consideration(
          demanded.consideration_id
        ) candidate
        order by candidate.captain_id
      loop
        perform pg_advisory_xact_lock(
          hashtextextended(lock_candidate.captain_id::text,1)
        );
      end loop;

      update pace_v2.captain_duty_reservations reservation
      set state='released',
          released_at=now(),
          release_reason=p_source
      where reservation.departure_id=p_departure_id
        and reservation.state in('provisional','held_t72')
        and not(reservation.vehicle_consideration_id=any(demanded_ids));

      if demanded_count=0 then
        return query select 'reserved'::text,0,'{}'::uuid[];
        return;
      end if;

      with recursive demand as (
        select
          demanded.consideration_id,
          demanded.ordinality::integer as item_no,
          demanded_count as item_count
        from unnest(demanded_ids) with ordinality
          demanded(consideration_id,ordinality)
      ), matching(
        item_no,item_count,consideration_ids,captain_ids
      ) as (
        select 0,demanded_count,array[]::uuid[],array[]::uuid[]
        union all
        select
          matching.item_no+1,
          matching.item_count,
          case when candidate.captain_id is null
            then matching.consideration_ids
            else matching.consideration_ids||demand.consideration_id
          end,
          case when candidate.captain_id is null
            then matching.captain_ids
            else matching.captain_ids||candidate.captain_id
          end
        from matching
        join demand on demand.item_no=matching.item_no+1
        cross join lateral (
          select option.captain_id
          from (
            select null::uuid as captain_id,-1 as state_priority,
              -1 as captain_priority
            union all
            select available.captain_id,
              case coalesce(existing.state,'')
                when 'confirmed_t24' then 0
                when 'held_t72' then 1
                when 'provisional' then 2
                else 3
              end,
              available.priority
            from pace_v2.captain_candidates_for_consideration(
              demand.consideration_id
            ) available
            left join pace_v2.captain_duty_reservations existing
              on existing.vehicle_consideration_id=demand.consideration_id
             and existing.captain_id=available.captain_id
             and existing.state in('provisional','held_t72','confirmed_t24')
          ) option
          order by option.state_priority,option.captain_priority,
            option.captain_id nulls first
        ) candidate
        where candidate.captain_id is null
           or candidate.captain_id<>all(matching.captain_ids)
      )
      select matching.consideration_ids,matching.captain_ids
      into matched_consideration_ids,matched_captain_ids
      from matching
      where matching.item_no=matching.item_count
      order by cardinality(matching.captain_ids) desc,
        matching.consideration_ids::text,matching.captain_ids::text
      limit 1;

      matched_count:=coalesce(cardinality(matched_captain_ids),0);
      select coalesce(array_agg(demanded.consideration_id order by demanded.ordinality),'{}'::uuid[])
      into unmatched_consideration_ids
      from unnest(demanded_ids) with ordinality demanded(consideration_id,ordinality)
      where not(demanded.consideration_id=any(matched_consideration_ids));

      set constraints pace_v2.captain_duty_reservations_no_overlap deferred;

      update pace_v2.captain_duty_reservations reservation
      set state='released',released_at=now(),release_reason=p_source
      where reservation.departure_id=p_departure_id
        and reservation.state in('provisional','held_t72')
        and reservation.vehicle_consideration_id=any(matched_consideration_ids)
        and reservation.captain_id is distinct from matched_captain_ids[
          array_position(matched_consideration_ids,reservation.vehicle_consideration_id)
        ];

      update pace_v2.captain_duty_reservations reservation
      set state='released',released_at=now(),release_reason=p_source
      where reservation.departure_id=p_departure_id
        and reservation.state in('provisional','held_t72')
        and reservation.vehicle_consideration_id=any(unmatched_consideration_ids);

      for item_index in 1..matched_count loop
        select * into current_consideration
        from pace_v2.vehicle_considerations
        where id=matched_consideration_ids[item_index];

        select * into current_resource
        from pace_v2.captain_duty_resource_window(p_departure_id);

        select * into existing_reservation
        from pace_v2.captain_duty_reservations reservation
        where reservation.vehicle_consideration_id=matched_consideration_ids[item_index]
          and reservation.state in('provisional','held_t72','confirmed_t24')
        for update;

        if found then
          selected_state:=case
            when existing_reservation.state='confirmed_t24' then 'confirmed_t24'
            when existing_reservation.state='held_t72' then 'held_t72'
            else p_target_state
          end;
          update pace_v2.captain_duty_reservations
          set captain_id=matched_captain_ids[item_index],
              duty_start_ts=current_resource.scheduled_start_ts,
              duty_end_ts=current_resource.scheduled_end_ts,
              state=selected_state,
              source=p_source,
              engine_version=p_source,
              promoted_at=case
                when selected_state='held_t72' then coalesce(promoted_at,now())
                else promoted_at
              end
          where id=existing_reservation.id;
        else
          insert into pace_v2.captain_duty_reservations(
            departure_id,vehicle_consideration_id,operator_id,vehicle_id,
            captain_id,duty_start_ts,duty_end_ts,state,source,engine_version,
            promoted_at
          ) values (
            p_departure_id,current_consideration.id,
            current_consideration.operator_id,current_consideration.vehicle_id,
            matched_captain_ids[item_index],current_resource.scheduled_start_ts,
            current_resource.scheduled_end_ts,p_target_state,p_source,p_source,
            case when p_target_state='held_t72' then now() end
          );
        end if;
      end loop;

      set constraints pace_v2.captain_duty_reservations_no_overlap immediate;
      return query select
        case when matched_count=demanded_count then 'reserved' else 'unavailable' end,
        matched_count,unmatched_consideration_ids;
      return;
    exception when exclusion_violation then
      if attempt=2 then
        return query select 'unavailable'::text,0,demanded_ids;
        return;
      end if;
    end;
  end loop;
end
$$;

create or replace function pace_v2.backfill_captain_duty_reservations()
returns table(
  backfilled_confirmed_count integer,
  conflict_count integer,
  reconciled_departure_count integer,
  shortage_count integer
)
language plpgsql security definer set search_path='' as $$
declare
  confirmed record;
  future_departure record;
  resource record;
  reconciliation record;
  v_backfilled integer:=0;
  v_conflicts integer:=0;
  v_reconciled integer:=0;
  v_shortages integer:=0;
  validation_failure text;
begin
  for confirmed in
    select
      allocation.id as allocation_id,
      allocation.departure_id,
      allocation.consideration_id,
      allocation.operator_id,
      allocation.vehicle_id,
      assignment.id as assignment_id,
      assignment.captain_id
    from pace_v2.confirmed_allocations allocation
    join pace_v2.departures departure on departure.id=allocation.departure_id
    left join lateral (
      select active_assignment.id,active_assignment.captain_id
      from pace_v2.captain_assignments active_assignment
      where active_assignment.confirmed_allocation_id=allocation.id
        and active_assignment.active
      order by active_assignment.assigned_at,active_assignment.id
      limit 1
    ) assignment on true
    where allocation.status='confirmed'
      and departure.status in('confirmed','active')
      and departure.scheduled_arrival_ts+interval '30 minutes'>now()
    order by departure.scheduled_departure_ts,allocation.id
  loop
    if exists(
      select 1 from pace_v2.captain_duty_reservations reservation
      where reservation.confirmed_allocation_id=confirmed.allocation_id
        and reservation.state='confirmed_t24'
    ) then
      update pace_v2.operational_alerts
      set resolved_at=coalesce(resolved_at,now()),
          resolution_note=coalesce(resolution_note,'Captain reservation backfill later succeeded.')
      where exception_key='captain_reservation_backfill_conflict:'||confirmed.allocation_id::text
        and resolved_at is null;
      continue;
    end if;

    validation_failure:=null;
    if confirmed.assignment_id is null then
      validation_failure:='active captain assignment missing';
    elsif not exists(
      select 1
      from pace_v2.vehicle_considerations consideration
      join pace_v2.vehicles vehicle
        on vehicle.id=consideration.vehicle_id
       and vehicle.active
      join pace_v2.captains captain
        on captain.id=confirmed.captain_id
       and captain.operator_id=confirmed.operator_id
       and captain.active
      join pace_v2.captain_vehicle_types eligibility
        on eligibility.captain_id=captain.id
       and eligibility.vehicle_type_id=vehicle.vehicle_type_id
       and eligibility.active
      left join pace_v2.vehicle_route_offers route_offer
        on route_offer.id=consideration.vehicle_route_offer_id
      left join pace_v2.vehicle_captain_preferences preference
        on preference.vehicle_id=vehicle.id
       and preference.operator_id=confirmed.operator_id
       and preference.captain_id=captain.id
       and preference.active
      where consideration.id=confirmed.consideration_id
        and consideration.departure_id=confirmed.departure_id
        and consideration.vehicle_id=confirmed.vehicle_id
        and consideration.operator_id=confirmed.operator_id
        and (
          (route_offer.preferred_captain_id is not null
           and route_offer.preferred_captain_id=captain.id)
          or
          (route_offer.preferred_captain_id is null
           and preference.captain_id is not null)
        )
    ) then
      validation_failure:='captain is inactive, ineligible or no longer configured';
    end if;

    select * into resource
    from pace_v2.captain_duty_resource_window(confirmed.departure_id);
    if resource.scheduled_start_ts is null then
      validation_failure:=coalesce(validation_failure,'canonical duty window missing');
    end if;

    if validation_failure is null then
      begin
        insert into pace_v2.captain_duty_reservations(
          departure_id,vehicle_consideration_id,operator_id,vehicle_id,
          captain_id,duty_start_ts,duty_end_ts,state,
          confirmed_allocation_id,captain_assignment_id,
          source,engine_version,promoted_at
        ) values(
          confirmed.departure_id,confirmed.consideration_id,
          confirmed.operator_id,confirmed.vehicle_id,confirmed.captain_id,
          resource.scheduled_start_ts,resource.scheduled_end_ts,'confirmed_t24',
          confirmed.allocation_id,confirmed.assignment_id,
          'migration-backfill','captain-reservation-v1',now()
        );
        v_backfilled:=v_backfilled+1;
        update pace_v2.operational_alerts
        set resolved_at=coalesce(resolved_at,now()),
            resolution_note=coalesce(resolution_note,'Captain reservation backfill later succeeded.')
        where exception_key='captain_reservation_backfill_conflict:'||confirmed.allocation_id::text
          and resolved_at is null;
      exception when exclusion_violation or unique_violation then
        validation_failure:='captain duty overlaps another active reservation';
      end;
    end if;

    if validation_failure is not null then
      v_conflicts:=v_conflicts+1;
      insert into pace_v2.operational_alerts(
        exception_key,exception_type,severity,confirmed_allocation_id,
        departure_id,details
      ) values(
        'captain_reservation_backfill_conflict:'||confirmed.allocation_id::text,
        'captain_reservation_backfill_conflict','high',confirmed.allocation_id,
        confirmed.departure_id,jsonb_build_object(
          'confirmed_allocation_id',confirmed.allocation_id,
          'departure_id',confirmed.departure_id,
          'consideration_id',confirmed.consideration_id,
          'vehicle_id',confirmed.vehicle_id,
          'operator_id',confirmed.operator_id,
          'captain_id',confirmed.captain_id,
          'reason',validation_failure
        )
      ) on conflict(exception_key) where resolved_at is null
      do update set detected_at=excluded.detected_at,details=excluded.details;
    end if;
  end loop;

  for future_departure in
    select distinct departure.id,departure.t72_ts
    from pace_v2.departures departure
    join pace_v2.bookings booking
      on booking.departure_id=departure.id
     and booking.status in('booked','at_risk','confirmed')
    join pace_v2.booking_allocations allocation
      on allocation.booking_id=booking.id
     and allocation.status in('preliminary','confirmed')
    where departure.scheduled_departure_ts>now()
      and departure.status not in(
        'confirmed','active','completed','cancelled','closed_unrecorded'
      )
      and not exists(
        select 1 from pace_v2.confirmed_allocations confirmed_allocation
        where confirmed_allocation.departure_id=departure.id
          and confirmed_allocation.status='confirmed'
      )
    order by departure.id
  loop
    perform pace_v2.refresh_consideration_totals(future_departure.id);
    select * into reconciliation
    from pace_v2.reconcile_departure_captain_reservations(
      future_departure.id,
      case when now()>=future_departure.t72_ts then 'held_t72' else 'provisional' end,
      'migration-backfill'
    );
    v_reconciled:=v_reconciled+1;

    if reconciliation.outcome='reserved' then
      update pace_v2.operational_alerts
      set resolved_at=coalesce(resolved_at,now()),
          resolution_note=coalesce(resolution_note,'Captain reservation reconciliation later succeeded.')
      where exception_key='captain_reservation_backfill_shortage:'||future_departure.id::text
        and resolved_at is null;
    else
      v_shortages:=v_shortages+1;
      update pace_v2.departures
      set status='at_risk',
          at_risk_reason='Captain reservation backfill found paid demand without staffable captain coverage.',
          updated_at=now()
      where id=future_departure.id;
      update pace_v2.bookings
      set status='at_risk',updated_at=now()
      where departure_id=future_departure.id and status='booked';
      insert into pace_v2.operational_alerts(
        exception_key,exception_type,severity,departure_id,details
      ) values(
        'captain_reservation_backfill_shortage:'||future_departure.id::text,
        'captain_reservation_backfill_conflict','high',future_departure.id,
        jsonb_build_object(
          'departure_id',future_departure.id,
          'unreserved_consideration_ids',reconciliation.unreserved_consideration_ids
        )
      ) on conflict(exception_key) where resolved_at is null
      do update set detected_at=excluded.detected_at,details=excluded.details;
    end if;
  end loop;

  return query select v_backfilled,v_conflicts,v_reconciled,v_shortages;
end
$$;

revoke all on function pace_v2.backfill_captain_duty_reservations()
  from public,anon,authenticated,service_role;

alter table pace_v2.vehicle_considerations
  add column if not exists captain_resource_reason text
  check(captain_resource_reason is null or captain_resource_reason in(
    'captain_conflict','no_eligible_captain','captain_inactive','captain_ineligible'
  ));

alter function pace_v2.evaluate_t72_booked_parties(uuid,text)
  rename to evaluate_t72_booked_parties_commercial;

create or replace function pace_v2.evaluate_t72_booked_parties(
  p_departure_id uuid,
  p_engine_version text default 'consideration-v0.3'
)
returns table(
  outcome text,
  viable_vehicle_count integer,
  total_booked_seats integer,
  total_booked_revenue_cents integer,
  rescue_gap_cents integer
)
language plpgsql security definer set search_path='' as $$
declare
  commercial_result record;
  reservation_result record;
  resource_id uuid;
  held_count integer;
  uncovered_count integer;
begin
  select * into commercial_result
  from pace_v2.evaluate_t72_booked_parties_commercial(
    p_departure_id,p_engine_version
  );

  if commercial_result.outcome like 'already_%'
     or commercial_result.outcome='cancelled_no_bookings' then
    return query select
      commercial_result.outcome,
      commercial_result.viable_vehicle_count,
      commercial_result.total_booked_seats,
      commercial_result.total_booked_revenue_cents,
      commercial_result.rescue_gap_cents;
    return;
  end if;

  select * into reservation_result
  from pace_v2.reconcile_departure_captain_reservations(
    p_departure_id,'held_t72','t72-captain-reservation-v1'
  );

  update pace_v2.vehicle_considerations consideration
  set captain_resource_reason=null,updated_at=now()
  where consideration.departure_id=p_departure_id
    and consideration.status='under_consideration'
    and exists (
      select 1
      from pace_v2.captain_duty_reservations reservation
      where reservation.vehicle_consideration_id=consideration.id
        and reservation.state='held_t72'
    );

  if cardinality(reservation_result.unreserved_consideration_ids)>0 then
    foreach resource_id in array reservation_result.unreserved_consideration_ids loop
      update pace_v2.vehicle_considerations
      set status='discarded_t72',
          t72_discarded_at=coalesce(t72_discarded_at,now()),
          captain_resource_reason='captain_conflict',
          updated_at=now()
      where id=resource_id
        and departure_id=p_departure_id;
    end loop;

    perform pace_v2.refresh_consideration_totals(p_departure_id);

    select count(*) into uncovered_count
    from pace_v2.bookings booking
    where booking.departure_id=p_departure_id
      and booking.status in('booked','at_risk','confirmed')
      and not exists (
        select 1
        from pace_v2.booking_allocations allocation
        join pace_v2.vehicle_considerations consideration
          on consideration.id=allocation.vehicle_consideration_id
         and consideration.status='under_consideration'
        join pace_v2.captain_duty_reservations reservation
          on reservation.vehicle_consideration_id=consideration.id
         and reservation.state='held_t72'
        where allocation.booking_id=booking.id
          and allocation.status in('preliminary','confirmed')
          and allocation.seats=booking.seats
      );

    if uncovered_count>0 then
      update pace_v2.departures
      set status='at_risk',
          at_risk_reason='T-72 captain resource shortage left one or more paid parties uncovered.',
          updated_at=now()
      where id=p_departure_id;

      update pace_v2.bookings
      set status='at_risk',updated_at=now()
      where departure_id=p_departure_id and status='booked';
    end if;

    insert into pace_v2.allocation_decisions(
      departure_id,decision_type,engine_version,
      decision_reason_code,decision_reason_text,
      input_snapshot,candidate_snapshot,commercial_snapshot,
      quality_snapshot,fairness_snapshot
    )
    select
      p_departure_id,'t72_booked_parties',p_engine_version,
      'T72_CAPTAIN_CONFLICT',
      'One or more vehicles were removed because no distinct eligible captain could be held for the complete duty window.',
      jsonb_build_object(
        'uncovered_booking_count',uncovered_count,
        'unreserved_consideration_ids',reservation_result.unreserved_consideration_ids
      ),
      coalesce(jsonb_agg(jsonb_build_object(
        'consideration_id',consideration.id,
        'vehicle_id',consideration.vehicle_id,
        'operator_id',consideration.operator_id,
        'resulting_status',consideration.status
      ) order by consideration.id),'[]'::jsonb),
      jsonb_build_object('manual_review_required',uncovered_count>0),
      '{}'::jsonb,'{}'::jsonb
    from pace_v2.vehicle_considerations consideration
    where consideration.id=any(reservation_result.unreserved_consideration_ids);

    insert into pace_v2.operational_alerts(
      exception_key,exception_type,severity,departure_id,details
    )
    select
      'captain_resource_shortage:'||p_departure_id::text,
      'captain_resource_shortage','high',p_departure_id,
      jsonb_build_object(
        'resources',coalesce(jsonb_agg(jsonb_build_object(
          'consideration_id',conflict.consideration_id,
          'vehicle_id',conflict.vehicle_id,
          'operator_id',conflict.operator_id,
          'conflicting_departure_id',conflict.conflicting_departure_id
        ) order by conflict.consideration_id),'[]'::jsonb)
      )
    from (
      select
        consideration.id as consideration_id,
        consideration.vehicle_id,
        consideration.operator_id,
        (
          select other.departure_id
          from pace_v2.captain_duty_reservations other
          join pace_v2.captains captain
            on captain.id=other.captain_id
           and captain.operator_id=consideration.operator_id
          join pace_v2.vehicles vehicle on vehicle.id=consideration.vehicle_id
          join pace_v2.captain_vehicle_types eligibility
            on eligibility.captain_id=captain.id
           and eligibility.vehicle_type_id=vehicle.vehicle_type_id
           and eligibility.active
          cross join lateral pace_v2.captain_duty_resource_window(
            p_departure_id
          ) duty
          where other.state in('provisional','held_t72','confirmed_t24')
            and other.vehicle_consideration_id<>consideration.id
            and other.duty_window && tstzrange(
              duty.scheduled_start_ts,duty.scheduled_end_ts,'[)'
            )
          order by other.duty_start_ts,other.id
          limit 1
        ) as conflicting_departure_id
      from pace_v2.vehicle_considerations consideration
      where consideration.id=any(reservation_result.unreserved_consideration_ids)
    ) conflict
    on conflict (exception_key) where resolved_at is null
    do update set detected_at=excluded.detected_at,details=excluded.details;
  end if;

  select count(*) into held_count
  from pace_v2.captain_duty_reservations reservation
  where reservation.departure_id=p_departure_id
    and reservation.state='held_t72';

  return query select
    case
      when cardinality(reservation_result.unreserved_consideration_ids)>0
        then 'at_risk_captain_resource_shortage'::text
      else commercial_result.outcome
    end,
    held_count,
    commercial_result.total_booked_seats,
    commercial_result.total_booked_revenue_cents,
    commercial_result.rescue_gap_cents;
end
$$;

create or replace function pace_v2.process_departure_t72(
  p_departure_id uuid,
  p_engine_version text default 'scheduler-v1.3',
  p_force boolean default false
)
returns jsonb
language plpgsql security definer set search_path='pace_v2','public' as $$
declare
  d pace_v2.departures%rowtype;
  jr uuid;
  booking_count integer;
  result jsonb;
  r record;
begin
  select * into d from pace_v2.departures where id=p_departure_id for update;
  if not found then raise exception 'Departure not found'; end if;
  if not d.is_commercial then return jsonb_build_object('outcome','not_commercial'); end if;
  if not p_force and now()<d.t72_ts then return jsonb_build_object('outcome','not_due'); end if;

  insert into pace_v2.scheduled_job_runs(
    job_name,departure_id,phase,scheduled_for,engine_version
  ) values('departure_window_processor',d.id,'t72',d.t72_ts,p_engine_version)
  on conflict do nothing returning id into jr;
  if jr is null then return jsonb_build_object('outcome','already_processed'); end if;

  begin
    select coalesce(sum(booking.seats),0) into booking_count
    from pace_v2.bookings booking
    where booking.departure_id=d.id
      and booking.status in('booked','at_risk','confirmed');

    if booking_count=0 then
      update pace_v2.vehicle_considerations
      set status='cancelled',updated_at=now()
      where departure_id=d.id and status not in('withdrawn','replaced','cancelled');
      update pace_v2.departures
      set status='cancelled',cancelled_reason='Cancelled at T-72 — no bookings.',
          at_risk_reason=null
      where id=d.id;
      insert into pace_v2.allocation_decisions(
        departure_id,decision_type,engine_version,decision_reason_code,
        decision_reason_text,input_snapshot,candidate_snapshot,commercial_snapshot
      ) values(
        d.id,'t72_zero_booking',p_engine_version,'CANCELLED_NO_BOOKINGS_T72',
        'Cancelled at T-72 — no bookings.',jsonb_build_object('booked_seats',0),
        coalesce((select jsonb_agg(jsonb_build_object(
          'consideration_id',consideration.id,'vehicle_id',consideration.vehicle_id,
          'operator_id',consideration.operator_id,'resulting_status',consideration.status
        )) from pace_v2.vehicle_considerations consideration
        where consideration.departure_id=d.id),'[]'::jsonb),'{}'::jsonb
      );
      result:=jsonb_build_object('outcome','cancelled_no_bookings',
        'reason','Cancelled at T-72 — no bookings.');
    else
      perform pace_v2.refresh_vehicle_considerations(d.id,p_engine_version);
      select to_jsonb(evaluation) into result
      from pace_v2.evaluate_t72_booked_parties(d.id,p_engine_version) evaluation;

      for r in
        select distinct consideration.operator_id
        from pace_v2.vehicle_considerations consideration
        join pace_v2.captain_duty_reservations reservation
          on reservation.vehicle_consideration_id=consideration.id
         and reservation.state='held_t72'
        where consideration.departure_id=d.id
          and consideration.status='under_consideration'
      loop
        perform pace_v2.queue_notification(
          r.operator_id,null,d.id,'in_app','T72_UNDER_CONSIDERATION',
          'Journey under consideration',
          'One or more staffed vehicles are under consideration for this journey.',
          d.t72_ts
        );
      end loop;

      if exists(
        select 1 from pace_v2.departures departure
        where departure.id=d.id and departure.status='at_risk'
      ) then
        for r in
          select booking.id from pace_v2.bookings booking
          where booking.departure_id=d.id
            and booking.status in('booked','at_risk','confirmed')
        loop
          perform pace_v2.queue_notification(
            null,r.id,d.id,'in_app','T72_AT_RISK','Journey update',
            'Your journey is currently at risk. Pace Shuttles is working to confirm the service.',
            d.t72_ts
          );
        end loop;
      end if;
    end if;

    update pace_v2.scheduled_job_runs
    set status='completed',completed_at=now(),outcome=coalesce(result,'{}'::jsonb)
    where id=jr;
    return coalesce(result,'{}'::jsonb);
  exception when others then
    update pace_v2.scheduled_job_runs
    set status='failed',completed_at=now(),failure_message=sqlerrm
    where id=jr;
    raise;
  end;
end
$$;

create or replace function pace_v2.queue_informative_t72_operator_email()
returns trigger
language plpgsql security definer set search_path='' as $$
declare
  v_email text;
  v_journey_name text;
  v_departure_date text;
  v_departure_time text;
  v_t24_date text;
  v_t24_time text;
  v_vehicles jsonb;
  v_metadata jsonb;
begin
  if new.channel<>'in_app'
     or new.template_code<>'T72_UNDER_CONSIDERATION'
     or new.operator_id is null
     or new.departure_id is null then
    return new;
  end if;

  select
    coalesce(nullif(trim(fleet_operator.notification_email),''),
      nullif(trim(fleet_operator.contact_email),''),
      nullif(trim(fleet_operator.admin_email),''),
      nullif(trim(fleet_operator.email),'')),
    coalesce(nullif(trim(route.route_name),''),nullif(trim(route.name),'')),
    to_char(departure.scheduled_departure_ts at time zone
      coalesce(nullif(departure.trip_timezone,''),'UTC'),'FMDay, FMDD FMMonth YYYY'),
    to_char(departure.scheduled_departure_ts at time zone
      coalesce(nullif(departure.trip_timezone,''),'UTC'),'FMHH12:MI am'),
    to_char(departure.t24_ts at time zone
      coalesce(nullif(departure.trip_timezone,''),'UTC'),'FMDay, FMDD FMMonth YYYY'),
    to_char(departure.t24_ts at time zone
      coalesce(nullif(departure.trip_timezone,''),'UTC'),'FMHH12:MI am')
  into v_email,v_journey_name,v_departure_date,v_departure_time,v_t24_date,v_t24_time
  from pace_v2.departures departure
  join pace_v2.routes route on route.id=departure.route_id
  join pace_v2.operators fleet_operator
    on fleet_operator.id=new.operator_id and fleet_operator.active
  where departure.id=new.departure_id;

  if not found or not pace_v2.is_valid_customer_notification_email(v_email) then
    return new;
  end if;

  select jsonb_agg(jsonb_build_object(
    'vehicleType',resource.vehicle_type,
    'vehicleName',resource.vehicle_name,
    'captainName',resource.captain_name
  ) order by resource.vehicle_name,resource.vehicle_id)
  into v_vehicles
  from (
    select distinct
      vehicle.id as vehicle_id,vehicle.name as vehicle_name,
      vehicle_type.name as vehicle_type,
      concat_ws(' ',captain.first_name,captain.last_name) as captain_name
    from pace_v2.vehicle_considerations consideration
    join pace_v2.captain_duty_reservations reservation
      on reservation.vehicle_consideration_id=consideration.id
     and reservation.state='held_t72'
    join pace_v2.captains captain
      on captain.id=reservation.captain_id
     and captain.operator_id=consideration.operator_id
     and captain.active
    join pace_v2.vehicles vehicle on vehicle.id=consideration.vehicle_id
    join pace_v2.vehicle_types vehicle_type on vehicle_type.id=vehicle.vehicle_type_id
    where consideration.departure_id=new.departure_id
      and consideration.operator_id=new.operator_id
      and consideration.status='under_consideration'
  ) resource;

  if v_vehicles is null or jsonb_array_length(v_vehicles)=0 then return new; end if;

  v_metadata:=jsonb_build_object(
    'sourceNotificationId',new.id::text,'journeyName',v_journey_name,
    'departureDate',v_departure_date,'departureTime',v_departure_time,
    't24Date',v_t24_date,'t24Time',v_t24_time,
    'operatorPortalUrl','https://www.paceshuttles.com/operator',
    'vehicles',v_vehicles
  );

  insert into pace_v2.notifications(
    operator_id,departure_id,channel,template_code,subject,body,
    status,to_email,scheduled_at,metadata
  ) values(
    new.operator_id,new.departure_id,'email','T72_UNDER_CONSIDERATION',
    'Journey under consideration',
    'Your under-consideration resources are ready to review in the Operator Portal.',
    'queued',v_email,new.scheduled_at,v_metadata
  ) on conflict do nothing;
  return new;
end
$$;

revoke all on function pace_v2.evaluate_t72_booked_parties(uuid,text)
  from public,anon,authenticated,service_role;

create or replace function pace_v2.confirm_reserved_captain(
  p_confirmed_allocation_id uuid,
  p_reservation_id uuid
)
returns uuid
language plpgsql security definer set search_path='' as $$
declare
  allocation pace_v2.confirmed_allocations%rowtype;
  reservation pace_v2.captain_duty_reservations%rowtype;
  assignment_id uuid;
  candidate_priority integer;
begin
  select * into allocation
  from pace_v2.confirmed_allocations
  where id=p_confirmed_allocation_id
  for update;
  if not found or allocation.status<>'confirmed' then
    raise exception 'active confirmed allocation is required';
  end if;

  select * into reservation
  from pace_v2.captain_duty_reservations
  where id=p_reservation_id
  for update;
  if not found or reservation.state<>'held_t72' then
    raise exception 'held T-72 captain reservation is required';
  end if;
  if reservation.departure_id<>allocation.departure_id
     or reservation.vehicle_consideration_id<>allocation.consideration_id
     or reservation.vehicle_id<>allocation.vehicle_id
     or reservation.operator_id<>allocation.operator_id then
    raise exception 'captain reservation does not match confirmed allocation';
  end if;
  if reservation.duty_window
     is distinct from pace_v2.captain_reservation_window(allocation.departure_id) then
    raise exception 'captain reservation duty window is stale';
  end if;

  select candidate.priority into candidate_priority
  from pace_v2.captain_candidates_for_consideration(allocation.consideration_id) candidate
  where candidate.captain_id=reservation.captain_id;
  if candidate_priority is null then
    raise exception 'reserved captain is no longer active and eligible';
  end if;

  select assignment.id into assignment_id
  from pace_v2.captain_assignments assignment
  where assignment.confirmed_allocation_id=allocation.id
    and assignment.active
  for update;

  if assignment_id is not null then
    if not exists(
      select 1 from pace_v2.captain_assignments assignment
      where assignment.id=assignment_id
        and assignment.captain_id=reservation.captain_id
    ) then
      raise exception 'confirmed allocation already has a different active captain';
    end if;
  else
    insert into pace_v2.captain_assignments(
      confirmed_allocation_id,captain_id,assignment_source,priority_used,active
    ) values(
      allocation.id,reservation.captain_id,'t72_reservation',candidate_priority,true
    ) returning id into assignment_id;
  end if;

  update pace_v2.captain_duty_reservations
  set state='confirmed_t24',
      confirmed_allocation_id=allocation.id,
      captain_assignment_id=assignment_id,
      promoted_at=coalesce(promoted_at,now()),
      source='t24-confirmation-v1',
      engine_version='t24-confirmation-v1'
  where id=reservation.id;

  return assignment_id;
end
$$;

create or replace function pace_v2.release_captain_reservations(
  p_departure_id uuid,
  p_reason text
)
returns integer
language plpgsql security definer set search_path='' as $$
declare
  released_count integer;
begin
  if nullif(btrim(p_reason),'') is null then
    raise exception 'captain reservation release reason is required';
  end if;

  update pace_v2.captain_duty_reservations
  set state='released',released_at=now(),release_reason=p_reason
  where departure_id=p_departure_id
    and state in('provisional','held_t72','confirmed_t24');
  get diagnostics released_count=row_count;
  return released_count;
end
$$;

create or replace function pace_v2.auto_assign_captain(
  p_confirmed_allocation_id uuid
)
returns uuid
language plpgsql security definer set search_path='' as $$
declare
  reservation_id uuid;
begin
  select reservation.id into reservation_id
  from pace_v2.captain_duty_reservations reservation
  join pace_v2.confirmed_allocations allocation
    on allocation.id=p_confirmed_allocation_id
   and allocation.departure_id=reservation.departure_id
   and allocation.consideration_id=reservation.vehicle_consideration_id
   and allocation.vehicle_id=reservation.vehicle_id
   and allocation.operator_id=reservation.operator_id
  where reservation.state='held_t72'
  order by reservation.created_at,reservation.id
  limit 1;

  if reservation_id is null then return null; end if;
  return pace_v2.confirm_reserved_captain(
    p_confirmed_allocation_id,reservation_id
  );
end
$$;

alter function pace_v2.confirm_departure_t24(uuid,boolean,text)
  rename to confirm_departure_t24_commercial;

create or replace function pace_v2.confirm_departure_t24(
  p_departure_id uuid,
  p_force boolean default false,
  p_engine_version text default 't24-v0.6.1'
)
returns table(
  outcome text,
  confirmed_vehicle_count integer,
  confirmed_booking_count integer,
  unassigned_captain_count integer
)
language plpgsql security definer set search_path='' as $$
declare
  departure_status text;
  demanded_count integer;
  reservation_result record;
  commercial_result record;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_departure_id::text,1));
  select departure.status::text into departure_status
  from pace_v2.departures departure
  where departure.id=p_departure_id
  for update;
  if departure_status is null then raise exception 'Departure % not found',p_departure_id; end if;

  select count(*) into demanded_count
  from pace_v2.vehicle_considerations consideration
  where consideration.departure_id=p_departure_id
    and consideration.status='under_consideration'
    and consideration.assigned_seats>0;

  if departure_status not in('confirmed','completed','cancelled')
     and demanded_count>0 then
    select * into reservation_result
    from pace_v2.reconcile_departure_captain_reservations(
      p_departure_id,'held_t72','t24-preflight-v1'
    );

    if reservation_result.outcome<>'reserved' then
      update pace_v2.departures
      set status='at_risk',
          at_risk_reason='T-24 confirmation requires manual review: insufficient eligible captains for the surviving vehicles.',
          updated_at=now()
      where id=p_departure_id;
      update pace_v2.bookings
      set status='at_risk',updated_at=now()
      where departure_id=p_departure_id and status in('booked','confirmed');

      insert into pace_v2.allocation_decisions(
        departure_id,decision_type,engine_version,decision_reason_code,
        decision_reason_text,input_snapshot,candidate_snapshot,
        commercial_snapshot,quality_snapshot,fairness_snapshot
      ) values(
        p_departure_id,'t24_manual_review',p_engine_version,
        'T24_INSUFFICIENT_CAPTAINS',
        'T-24 confirmation was withheld because every surviving vehicle did not have a distinct held captain.',
        jsonb_build_object(
          'manual_review_required',true,
          'unreserved_consideration_ids',reservation_result.unreserved_consideration_ids
        ),'[]'::jsonb,jsonb_build_object('customer_prices_changed',false),
        '{}'::jsonb,'{}'::jsonb
      );

      return query select
        'at_risk_manual_review'::text,0,0,
        cardinality(reservation_result.unreserved_consideration_ids);
      return;
    end if;
  end if;

  select * into commercial_result
  from pace_v2.confirm_departure_t24_commercial(
    p_departure_id,p_force,p_engine_version
  );
  return query select
    commercial_result.outcome,
    commercial_result.confirmed_vehicle_count,
    commercial_result.confirmed_booking_count,
    commercial_result.unassigned_captain_count;
end
$$;

create or replace function pace_v2.release_terminal_departure_captain_reservations()
returns trigger
language plpgsql security definer set search_path='' as $$
declare
  resource record;
begin
  if new.status is not distinct from old.status
     or new.status not in('completed','cancelled','closed_unrecorded') then
    return new;
  end if;

  select * into resource
  from pace_v2.captain_duty_resource_window(new.id);
  if resource.outbound_departure_id is null then return new; end if;

  if new.status in('cancelled','closed_unrecorded')
     or (new.status='completed' and new.id=resource.final_departure_id) then
    perform pace_v2.release_captain_reservations(
      resource.outbound_departure_id,'departure-'||new.status::text
    );
  end if;
  return new;
end
$$;

drop trigger if exists release_terminal_captain_reservations
  on pace_v2.departures;
create trigger release_terminal_captain_reservations
after update of status on pace_v2.departures
for each row execute function pace_v2.release_terminal_departure_captain_reservations();

create or replace function pace_v2.reconcile_captain_reservations_after_consideration_change()
returns trigger
language plpgsql security definer set search_path='' as $$
declare
  departure pace_v2.departures%rowtype;
  target_state text;
begin
  if new.status is not distinct from old.status
     or new.status not in('withdrawn','discarded_t72','cancelled','replaced') then
    return new;
  end if;
  select * into departure from pace_v2.departures where id=new.departure_id;
  if departure.status in('confirmed','active','completed','cancelled','closed_unrecorded') then
    return new;
  end if;
  target_state:=case when now()>=departure.t72_ts then 'held_t72' else 'provisional' end;
  perform * from pace_v2.reconcile_departure_captain_reservations(
    departure.id,target_state,'consideration-state-change'
  );
  return new;
end
$$;

drop trigger if exists reconcile_captain_reservations_after_consideration_change
  on pace_v2.vehicle_considerations;
create trigger reconcile_captain_reservations_after_consideration_change
after update of status on pace_v2.vehicle_considerations
for each row execute function pace_v2.reconcile_captain_reservations_after_consideration_change();

create or replace function pace_v2.reconcile_captain_reservations_after_resource_deactivation()
returns trigger
language plpgsql security definer set search_path='' as $$
declare
  affected record;
  reason_code text;
begin
  if new.active or old.active is not true then return new; end if;
  reason_code:=case tg_table_name
    when 'vehicles' then 'captain_inactive'
    else 'captain_ineligible'
  end;

  for affected in
    select distinct consideration.departure_id
    from pace_v2.vehicle_considerations consideration
    join pace_v2.departures departure on departure.id=consideration.departure_id
    where departure.scheduled_departure_ts>now()
      and departure.status not in(
        'confirmed','active','completed','cancelled','closed_unrecorded'
      )
      and (
        (tg_table_name='vehicles' and consideration.vehicle_id=new.id)
        or
        (tg_table_name='vehicle_route_offers'
         and consideration.vehicle_route_offer_id=new.id)
      )
  loop
    update pace_v2.vehicle_considerations consideration
    set status='discarded_t72',
        t72_discarded_at=coalesce(consideration.t72_discarded_at,now()),
        captain_resource_reason=reason_code,
        updated_at=now()
    where consideration.departure_id=affected.departure_id
      and (
        (tg_table_name='vehicles' and consideration.vehicle_id=new.id)
        or
        (tg_table_name='vehicle_route_offers'
         and consideration.vehicle_route_offer_id=new.id)
      )
      and consideration.status not in(
        'withdrawn','confirmed','replaced','cancelled','discarded_t72'
      );
  end loop;
  return new;
end
$$;

drop trigger if exists reconcile_captain_reservations_after_vehicle_deactivation
  on pace_v2.vehicles;
create trigger reconcile_captain_reservations_after_vehicle_deactivation
after update of active on pace_v2.vehicles
for each row execute function pace_v2.reconcile_captain_reservations_after_resource_deactivation();

drop trigger if exists reconcile_captain_reservations_after_route_offer_deactivation
  on pace_v2.vehicle_route_offers;
create trigger reconcile_captain_reservations_after_route_offer_deactivation
after update of active on pace_v2.vehicle_route_offers
for each row execute function pace_v2.reconcile_captain_reservations_after_resource_deactivation();

revoke all on function pace_v2.confirm_reserved_captain(uuid,uuid),
  pace_v2.release_captain_reservations(uuid,text)
  from public,anon,authenticated,service_role;
revoke all on function pace_v2.confirm_departure_t24(uuid,boolean,text),
  pace_v2.release_terminal_departure_captain_reservations(),
  pace_v2.reconcile_captain_reservations_after_consideration_change(),
  pace_v2.reconcile_captain_reservations_after_resource_deactivation()
  from public,anon,authenticated,service_role;

create or replace function pace_v2.site_admin_captain_conflicting_departure_id(
  p_consideration_id uuid
)
returns uuid
language plpgsql stable security definer set search_path='' as $$
declare
  conflicting_departure_id uuid;
begin
  if not pace_v2.is_site_admin() then return null; end if;

  select other.departure_id into conflicting_departure_id
  from pace_v2.vehicle_considerations consideration
  join pace_v2.vehicles vehicle on vehicle.id=consideration.vehicle_id
  left join pace_v2.vehicle_route_offers route_offer
    on route_offer.id=consideration.vehicle_route_offer_id
  cross join lateral pace_v2.captain_duty_resource_window(
    consideration.departure_id
  ) current_resource
  join pace_v2.captains captain
    on captain.operator_id=consideration.operator_id
   and captain.active
  join pace_v2.captain_vehicle_types eligibility
    on eligibility.captain_id=captain.id
   and eligibility.vehicle_type_id=vehicle.vehicle_type_id
   and eligibility.active
  left join pace_v2.vehicle_captain_preferences preference
    on preference.vehicle_id=consideration.vehicle_id
   and preference.operator_id=consideration.operator_id
   and preference.captain_id=captain.id
   and preference.active
  join pace_v2.captain_duty_reservations other
    on other.captain_id=captain.id
   and other.state in('provisional','held_t72','confirmed_t24')
   and other.vehicle_consideration_id<>consideration.id
   and other.duty_window && tstzrange(
     current_resource.scheduled_start_ts,current_resource.scheduled_end_ts,'[)'
   )
  where consideration.id=p_consideration_id
    and (
      (route_offer.preferred_captain_id is not null
       and route_offer.preferred_captain_id=captain.id)
      or
      (route_offer.preferred_captain_id is null
       and preference.captain_id is not null)
    )
  order by other.duty_start_ts,other.departure_id,other.id
  limit 1;

  return conflicting_departure_id;
end
$$;

revoke all on function pace_v2.site_admin_captain_conflicting_departure_id(uuid)
  from public,anon,authenticated,service_role;
grant execute on function pace_v2.site_admin_captain_conflicting_departure_id(uuid)
  to authenticated;

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
  vc.commercial_snapshot_locked_at,vc.commercial_snapshot_source,
  pace_v2.site_admin_conflicting_departure_id(vc.departure_id,vc.vehicle_id)
    as conflicting_departure_id,
  reservation.state as captain_resource_state,
  vc.captain_resource_reason as captain_resource_reason,
  reservation.captain_id as captain_id_reserved,
  pace_v2.site_admin_captain_conflicting_departure_id(vc.id)
    as captain_conflicting_departure_id
from pace_v2.vehicle_considerations vc
join pace_v2.vehicles v on v.id=vc.vehicle_id
join pace_v2.operators o on o.id=vc.operator_id
left join lateral (
  select claim.state,claim.captain_id
  from pace_v2.captain_duty_reservations claim
  where claim.vehicle_consideration_id=vc.id
  order by
    case when claim.state in('provisional','held_t72','confirmed_t24') then 0 else 1 end,
    claim.created_at desc,claim.id
  limit 1
) reservation on true
where pace_v2.is_site_admin();

revoke all on function pace_v2.reconcile_departure_captain_reservations(uuid,text,text)
  from public,anon,authenticated,service_role;

create or replace function pace_v2.allocate_paid_booking(p_booking_id uuid)
returns table(
  result_status text,
  vehicle_id uuid,
  vehicle_name text,
  operator_id uuid,
  operator_name text,
  vehicle_consideration_id uuid
)
language plpgsql security definer set search_path=pace_v2,public as $$
declare
  b pace_v2.bookings%rowtype;
  d pace_v2.departures%rowtype;
  offer record;
  reservation_result record;
begin
  select * into b from pace_v2.bookings where id=p_booking_id for update;
  if not found then raise exception 'booking not found'; end if;

  if exists(
    select 1 from pace_v2.booking_allocations allocation
    where allocation.booking_id=b.id
      and allocation.status in('preliminary','confirmed')
  ) then
    return query
    select 'allocated'::text,allocation.vehicle_id,vehicle.name,
      fleet_operator.id,fleet_operator.name,allocation.vehicle_consideration_id
    from pace_v2.booking_allocations allocation
    left join pace_v2.vehicles vehicle on vehicle.id=allocation.vehicle_id
    left join pace_v2.operators fleet_operator on fleet_operator.id=vehicle.operator_id
    where allocation.booking_id=b.id
      and allocation.status in('preliminary','confirmed')
    order by allocation.allocated_at desc
    limit 1;
    return;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(b.departure_id::text,0));
  select * into d from pace_v2.departures where id=b.departure_id for update;
  if d.id is null or d.status in('cancelled','completed') then
    return query select 'unavailable'::text,null::uuid,null::text,
      null::uuid,null::text,null::uuid;
    return;
  end if;

  select * into offer from pace_v2.get_live_party_offer(b.departure_id,b.seats);
  if offer.result_status<>'offer' then
    return query select offer.result_status,null::uuid,null::text,
      null::uuid,null::text,null::uuid;
    return;
  end if;

  insert into pace_v2.booking_allocations(
    booking_id,departure_id,vehicle_consideration_id,vehicle_id,status,seats,
    unit_price_cents,allocation_reason
  ) values (
    b.id,b.departure_id,offer.vehicle_consideration_id,offer.vehicle_id,
    'confirmed',b.seats,b.unit_price_cents,
    'Allocated only after successful customer payment'
  );

  perform pace_v2.refresh_live_consideration_states(b.departure_id);
  select * into reservation_result
  from pace_v2.reconcile_departure_captain_reservations(
    b.departure_id,'provisional','paid-allocation-v1'
  );

  if reservation_result.outcome<>'reserved' then
    update pace_v2.booking_allocations
    set status='cancelled'
    where booking_id=b.id
      and vehicle_consideration_id=offer.vehicle_consideration_id
      and status='confirmed';
    perform pace_v2.refresh_live_consideration_states(b.departure_id);
    perform * from pace_v2.reconcile_departure_captain_reservations(
      b.departure_id,'provisional','paid-allocation-rollback'
    );
    return query select 'unavailable'::text,null::uuid,null::text,
      null::uuid,null::text,null::uuid;
    return;
  end if;

  update pace_v2.bookings
  set status='booked',paid_at=coalesce(paid_at,now()),
      preliminary_vehicle_id=offer.vehicle_id,updated_at=now(),
      commercial_snapshot=coalesce(commercial_snapshot,'{}'::jsonb)
        ||jsonb_build_object(
          'post_payment_vehicle_consideration_id',offer.vehicle_consideration_id,
          'post_payment_vehicle_id',offer.vehicle_id,
          'post_payment_operator_id',offer.operator_id,
          'allocation_stage',offer.allocation_stage
        )
  where id=b.id;

  return query select 'allocated'::text,offer.vehicle_id,offer.vehicle_name,
    offer.operator_id,offer.operator_name,offer.vehicle_consideration_id;
end
$$;

create or replace function pace_v2.cancel_booking_and_request_refund(
  p_booking_id uuid,
  p_requested_refund_cents integer,
  p_reason text,
  p_initiated_by text default 'customer'
)
returns uuid
language plpgsql security definer set search_path=pace_v2,public as $$
declare
  b pace_v2.bookings%rowtype;
  cancellation_id uuid;
  request_id uuid;
begin
  select * into b
  from pace_v2.bookings
  where id=p_booking_id
  for update;

  if not found then raise exception 'Booking % not found',p_booking_id; end if;
  if b.status in('completed','refunded') then
    raise exception 'Booking % cannot be cancelled from status %',p_booking_id,b.status;
  end if;
  if p_requested_refund_cents<0
     or p_requested_refund_cents>b.total_price_cents then
    raise exception 'Refund request must be between 0 and booking total % cents',
      b.total_price_cents;
  end if;

  insert into pace_v2.cancellation_events(
    event_scope,booking_id,departure_id,reason_text,initiated_by,
    financial_snapshot
  ) values (
    'booking',b.id,b.departure_id,p_reason,p_initiated_by,
    jsonb_build_object(
      'booking_total_cents',b.total_price_cents,
      'requested_refund_cents',p_requested_refund_cents,
      'currency',b.currency
    )
  ) returning id into cancellation_id;

  update pace_v2.bookings set status='cancelled',updated_at=now() where id=b.id;
  update pace_v2.booking_allocations
  set status='cancelled'
  where booking_id=b.id and status in('preliminary','confirmed');

  perform pace_v2.refresh_live_consideration_states(b.departure_id);
  perform * from pace_v2.reconcile_departure_captain_reservations(
    b.departure_id,'provisional','booking-cancelled'
  );

  insert into pace_v2.refund_requests(
    booking_id,order_id,cancellation_event_id,currency,
    requested_refund_cents,status,reason,requested_by
  ) values (
    b.id,b.order_id,cancellation_id,b.currency,p_requested_refund_cents,
    case when p_requested_refund_cents=0 then 'cancelled' else 'requested' end,
    p_reason,p_initiated_by
  ) returning id into request_id;

  return request_id;
end
$$;

-- Reconcile existing future work only after every reservation-aware lifecycle
-- function, projection and release trigger in this migration is installed.
select * from pace_v2.backfill_captain_duty_reservations();
