-- Bind day-of timing evidence to the exact duty selected in the captain interface.
-- The nullable default preserves fail-closed compatibility for an older client
-- during deployment; shared-login requests without an allocation remain ambiguous.

drop function public.v2_captain_start_leg(uuid);
drop function public.v2_captain_end_leg(uuid,text,text,text);

create or replace function public.v2_captain_start_leg(
  p_departure_id uuid,
  p_confirmed_allocation_id uuid default null
)
returns timestamptz
language plpgsql security definer set search_path='' as $$
declare
  target_leg pace_v2.departures%rowtype;
  outbound_departure pace_v2.departures%rowtype;
  existing_operation pace_v2.captain_leg_operations%rowtype;
  previous_operation pace_v2.captain_leg_operations%rowtype;
  v_outbound_id uuid;
  v_final_id uuid;
  v_allocation_id uuid;
  v_assignment_id uuid;
  v_candidate_count integer;
  country_timezone text;
  v_started_at timestamptz;
  v_legacy_started_at timestamptz;
  v_legacy_ended_at timestamptz;
  v_legacy_completion_state text;
  v_legacy_notes text;
  v_legacy_summary text;
  v_locked_identity record;
begin
  if auth.uid() is null then raise exception 'captain assignment required'; end if;
  select * into v_locked_identity from pace_v2.lock_captain_duty_identity(p_departure_id);
  v_outbound_id:=v_locked_identity.outbound_departure_id;
  v_final_id:=v_locked_identity.final_departure_id;
  select * into target_leg from pace_v2.departures where id=v_locked_identity.target_departure_id;
  select * into outbound_departure from pace_v2.departures where id=v_outbound_id;
  if target_leg.id is distinct from v_locked_identity.target_departure_id
     or target_leg.id not in(v_outbound_id,v_final_id) then
    raise exception 'journey pair identity changed; retry action';
  end if;

  perform ca.id
  from pace_v2.confirmed_allocations ca
  join pace_v2.departures allocation_departure on ca.departure_id=allocation_departure.id
  join pace_v2.vehicles vehicle on vehicle.id=ca.vehicle_id and vehicle.active
  join pace_v2.captain_assignments assignment
    on assignment.confirmed_allocation_id=ca.id and assignment.active
  join pace_v2.captains captain on captain.id=assignment.captain_id
    and captain.active and captain.operator_id=ca.operator_id and captain.auth_user_id=auth.uid()
  join pace_v2.captain_vehicle_types eligibility on eligibility.captain_id=captain.id
    and eligibility.vehicle_type_id=vehicle.vehicle_type_id and eligibility.active
  where allocation_departure.id=v_outbound_id
    and (p_confirmed_allocation_id is null or ca.id=p_confirmed_allocation_id)
    and ca.status in('confirmed','completed')
  order by ca.id,assignment.id for update of ca,assignment;

  select count(*),
    (array_agg(ca.id order by ca.id,assignment.id))[1],
    (array_agg(assignment.id order by ca.id,assignment.id))[1],
    (array_agg(country.timezone order by ca.id,assignment.id))[1]
    into v_candidate_count,v_allocation_id,v_assignment_id,country_timezone
  from pace_v2.confirmed_allocations ca
  join pace_v2.departures allocation_departure on ca.departure_id=allocation_departure.id
  join pace_v2.routes route on route.id=allocation_departure.route_id
  join pace_v2.countries country on country.id=route.country_id
  join pace_v2.vehicles vehicle on vehicle.id=ca.vehicle_id and vehicle.active
  join pace_v2.captain_assignments assignment
    on assignment.confirmed_allocation_id=ca.id and assignment.active
  join pace_v2.captains captain on captain.id=assignment.captain_id
    and captain.active and captain.operator_id=ca.operator_id and captain.auth_user_id=auth.uid()
  join pace_v2.captain_vehicle_types eligibility on eligibility.captain_id=captain.id
    and eligibility.vehicle_type_id=vehicle.vehicle_type_id and eligibility.active
  where allocation_departure.id=v_outbound_id
    and (p_confirmed_allocation_id is null or ca.id=p_confirmed_allocation_id)
    and ca.status in('confirmed','completed');
  if v_candidate_count=0 then raise exception 'captain assignment required'; end if;
  if v_candidate_count>1 then raise exception 'captain duty is ambiguous for departure'; end if;
  if not exists(select 1 from pg_catalog.pg_timezone_names timezone_name where timezone_name.name=country_timezone) then
    raise exception 'captain duty timezone is invalid';
  end if;
  if not pace_v2.captain_duty_action_allowed(v_allocation_id,target_leg.id,v_outbound_id,v_final_id,country_timezone) then
    if pace_v2.captain_duty_recovery_expired(v_allocation_id,v_outbound_id,v_final_id) then
      raise exception 'captain duty recovery window expired; escalate to Site Admin';
    end if;
    raise exception 'captain duty is not operating today';
  end if;

  if target_leg.journey_pair_id is null then
    select
      coalesce((legacy.payload->>'actual_departure_ts')::timestamptz,target_leg.actual_departure_ts),
      coalesce((legacy.payload->>'actual_arrival_ts')::timestamptz,target_leg.actual_arrival_ts),
      case when coalesce((legacy.payload->>'actual_arrival_ts')::timestamptz,target_leg.actual_arrival_ts) is not null
        then case when coalesce((legacy.payload->>'incident_flag')::boolean,false) then 'incident' else 'normal' end
      end,
      legacy.payload->>'captain_notes',legacy.payload->>'incident_summary'
      into v_legacy_started_at,v_legacy_ended_at,v_legacy_completion_state,v_legacy_notes,v_legacy_summary
    from pace_v2.departures legacy_departure
    left join lateral(
      select to_jsonb(voyage) payload from pace_v2.voyage_logs voyage
      where voyage.confirmed_allocation_id=v_allocation_id
      order by voyage.created_at desc limit 1
    ) legacy on true
    where legacy_departure.id=target_leg.id;
  end if;

  insert into pace_v2.captain_leg_operations(
    confirmed_allocation_id,departure_id,captain_assignment_id,started_at,ended_at,
    completion_state,notes,incident_summary
  ) values(
    v_allocation_id,target_leg.id,v_assignment_id,v_legacy_started_at,v_legacy_ended_at,
    v_legacy_completion_state,v_legacy_notes,
    case when v_legacy_completion_state='incident' then v_legacy_summary else null end
  ) on conflict(confirmed_allocation_id,departure_id) do nothing;
  select * into existing_operation from pace_v2.captain_leg_operations
  where confirmed_allocation_id=v_allocation_id and departure_id=target_leg.id for update;
  if existing_operation.started_at is not null then
    if (target_leg.journey_pair_id is not null
         and existing_operation.started_by_user_id is distinct from auth.uid())
       or (existing_operation.ended_at is null
         and existing_operation.captain_assignment_id<>v_assignment_id) then
      raise exception 'captain assignment required';
    end if;
    return existing_operation.started_at;
  end if;
  if existing_operation.captain_assignment_id<>v_assignment_id then
    raise exception 'captain assignment required';
  end if;

  if target_leg.id<>v_outbound_id then
    select * into previous_operation from pace_v2.captain_leg_operations
    where confirmed_allocation_id=v_allocation_id and departure_id=v_outbound_id for update;
    if previous_operation.ended_at is null then raise exception 'leg transition out of order'; end if;
    if previous_operation.completion_state='incident' then
      raise exception 'incident-ended duty cannot start another leg; escalate to Site Admin';
    end if;
  end if;

  if target_leg.id=v_outbound_id then
    update pace_v2.captain_leg_operations
    set legacy_start_authorized=true
    where confirmed_allocation_id=v_allocation_id and departure_id=target_leg.id
      and started_at is null and ended_at is null;
    perform public.v2_captain_start_journey(p_captain_assignment_id=>v_assignment_id);
    update pace_v2.captain_leg_operations
    set legacy_start_authorized=false
    where confirmed_allocation_id=v_allocation_id and departure_id=target_leg.id;
    select coalesce((legacy.payload->>'actual_departure_ts')::timestamptz,departure.actual_departure_ts)
      into v_legacy_started_at
    from pace_v2.departures departure
    left join lateral(
      select to_jsonb(voyage) payload from pace_v2.voyage_logs voyage
      where voyage.confirmed_allocation_id=v_allocation_id
      order by voyage.created_at desc limit 1
    ) legacy on true
    where departure.id=v_outbound_id;
  end if;
  v_started_at:=coalesce(v_legacy_started_at,clock_timestamp());
  update pace_v2.captain_leg_operations
  set started_at=v_started_at,started_by_user_id=auth.uid(),legacy_start_authorized=false
  where confirmed_allocation_id=v_allocation_id and departure_id=target_leg.id and started_at is null;
  return v_started_at;
end $$;

create or replace function public.v2_captain_end_leg(
  p_departure_id uuid,
  p_completion_state text,
  p_notes text,
  p_incident_summary text,
  p_confirmed_allocation_id uuid default null
)
returns timestamptz
language plpgsql security definer set search_path='' as $$
declare
  target_leg pace_v2.departures%rowtype;
  outbound_departure pace_v2.departures%rowtype;
  final_leg pace_v2.departures%rowtype;
  existing_operation pace_v2.captain_leg_operations%rowtype;
  previous_operation pace_v2.captain_leg_operations%rowtype;
  v_outbound_id uuid;
  v_final_id uuid;
  v_allocation_id uuid;
  v_assignment_id uuid;
  v_candidate_count integer;
  country_timezone text;
  v_ended_at timestamptz;
  v_legacy_started_at timestamptz;
  v_legacy_ended_at timestamptz;
  v_legacy_completion_state text;
  v_legacy_notes text;
  v_legacy_summary text;
  v_incident_summary text;
  v_all_allocations_finished boolean:=false;
  v_locked_identity record;
  v_finalization record;
  v_original_auth_user text:=coalesce(current_setting('request.jwt.claim.sub',true),'');
begin
  if auth.uid() is null then raise exception 'captain assignment required'; end if;
  select * into v_locked_identity from pace_v2.lock_captain_duty_identity(p_departure_id);
  v_outbound_id:=v_locked_identity.outbound_departure_id;
  v_final_id:=v_locked_identity.final_departure_id;
  select * into target_leg from pace_v2.departures where id=v_locked_identity.target_departure_id;
  select * into outbound_departure from pace_v2.departures where id=v_outbound_id;
  select * into final_leg from pace_v2.departures where id=v_final_id;
  if target_leg.id is distinct from v_locked_identity.target_departure_id
     or target_leg.id not in(v_outbound_id,v_final_id)
     or final_leg.id is distinct from v_locked_identity.final_departure_id then
    raise exception 'journey pair identity changed; retry action';
  end if;

  perform ca.id
  from pace_v2.confirmed_allocations ca
  join pace_v2.departures allocation_departure on ca.departure_id=allocation_departure.id
  join pace_v2.vehicles vehicle on vehicle.id=ca.vehicle_id and vehicle.active
  join pace_v2.captain_assignments assignment
    on assignment.confirmed_allocation_id=ca.id and assignment.active
  join pace_v2.captains captain on captain.id=assignment.captain_id
    and captain.active and captain.operator_id=ca.operator_id and captain.auth_user_id=auth.uid()
  join pace_v2.captain_vehicle_types eligibility on eligibility.captain_id=captain.id
    and eligibility.vehicle_type_id=vehicle.vehicle_type_id and eligibility.active
  where allocation_departure.id=v_outbound_id
    and (p_confirmed_allocation_id is null or ca.id=p_confirmed_allocation_id)
    and ca.status in('confirmed','completed')
  order by ca.id,assignment.id for update of ca,assignment;

  select count(*),
    (array_agg(ca.id order by ca.id,assignment.id))[1],
    (array_agg(assignment.id order by ca.id,assignment.id))[1],
    (array_agg(country.timezone order by ca.id,assignment.id))[1]
    into v_candidate_count,v_allocation_id,v_assignment_id,country_timezone
  from pace_v2.confirmed_allocations ca
  join pace_v2.departures allocation_departure on ca.departure_id=allocation_departure.id
  join pace_v2.routes route on route.id=allocation_departure.route_id
  join pace_v2.countries country on country.id=route.country_id
  join pace_v2.vehicles vehicle on vehicle.id=ca.vehicle_id and vehicle.active
  join pace_v2.captain_assignments assignment
    on assignment.confirmed_allocation_id=ca.id and assignment.active
  join pace_v2.captains captain on captain.id=assignment.captain_id
    and captain.active and captain.operator_id=ca.operator_id and captain.auth_user_id=auth.uid()
  join pace_v2.captain_vehicle_types eligibility on eligibility.captain_id=captain.id
    and eligibility.vehicle_type_id=vehicle.vehicle_type_id and eligibility.active
  where allocation_departure.id=v_outbound_id
    and (p_confirmed_allocation_id is null or ca.id=p_confirmed_allocation_id)
    and ca.status in('confirmed','completed');
  if v_candidate_count=0 then raise exception 'captain assignment required'; end if;
  if v_candidate_count>1 then raise exception 'captain duty is ambiguous for departure'; end if;
  if not exists(select 1 from pg_catalog.pg_timezone_names timezone_name where timezone_name.name=country_timezone) then
    raise exception 'captain duty timezone is invalid';
  end if;
  if not pace_v2.captain_duty_action_allowed(v_allocation_id,target_leg.id,v_outbound_id,v_final_id,country_timezone) then
    if pace_v2.captain_duty_recovery_expired(v_allocation_id,v_outbound_id,v_final_id) then
      raise exception 'captain duty recovery window expired; escalate to Site Admin';
    end if;
    raise exception 'captain duty is not operating today';
  end if;
  if p_completion_state is null or p_completion_state not in ('normal','incident') then
    raise exception 'invalid completion state';
  end if;
  if p_completion_state='incident'
     and nullif(trim(coalesce(p_incident_summary,'')),'') is null then
    raise exception 'incident summary required';
  end if;
  if p_completion_state='normal'
     and nullif(trim(coalesce(p_incident_summary,'')),'') is not null then
    raise exception 'normal completion cannot include an incident summary';
  end if;
  v_incident_summary:=case when p_completion_state='incident' then p_incident_summary else null end;

  if target_leg.journey_pair_id is null then
    select
      coalesce((legacy.payload->>'actual_departure_ts')::timestamptz,target_leg.actual_departure_ts),
      coalesce((legacy.payload->>'actual_arrival_ts')::timestamptz,target_leg.actual_arrival_ts),
      case when coalesce((legacy.payload->>'actual_arrival_ts')::timestamptz,target_leg.actual_arrival_ts) is not null
        then case when coalesce((legacy.payload->>'incident_flag')::boolean,false) then 'incident' else 'normal' end
      end,
      legacy.payload->>'captain_notes',legacy.payload->>'incident_summary'
      into v_legacy_started_at,v_legacy_ended_at,v_legacy_completion_state,v_legacy_notes,v_legacy_summary
    from pace_v2.departures legacy_departure
    left join lateral(
      select to_jsonb(voyage) payload from pace_v2.voyage_logs voyage
      where voyage.confirmed_allocation_id=v_allocation_id
      order by voyage.created_at desc limit 1
    ) legacy on true
    where legacy_departure.id=target_leg.id;
    insert into pace_v2.captain_leg_operations(
      confirmed_allocation_id,departure_id,captain_assignment_id,started_at,ended_at,
      completion_state,notes,incident_summary
    ) values(
      v_allocation_id,target_leg.id,v_assignment_id,v_legacy_started_at,v_legacy_ended_at,
      v_legacy_completion_state,v_legacy_notes,
      case when v_legacy_completion_state='incident' then v_legacy_summary else null end
    ) on conflict(confirmed_allocation_id,departure_id) do nothing;
    if v_legacy_ended_at is not null then
      update pace_v2.captain_leg_operations
      set started_at=coalesce(started_at,v_legacy_started_at),ended_at=v_legacy_ended_at,
          completion_state=v_legacy_completion_state,notes=v_legacy_notes,
          incident_summary=case when v_legacy_completion_state='incident' then v_legacy_summary else null end,
          finalization_authorized=false
      where confirmed_allocation_id=v_allocation_id and departure_id=target_leg.id
        and ended_at is null;
    end if;
  end if;

  select * into existing_operation from pace_v2.captain_leg_operations
  where confirmed_allocation_id=v_allocation_id and departure_id=target_leg.id for update;
  if existing_operation.departure_id is null or existing_operation.started_at is null then
    raise exception 'leg transition out of order';
  end if;
  if existing_operation.ended_at is not null then
    if target_leg.journey_pair_id is not null
       and existing_operation.ended_by_user_id is distinct from auth.uid() then
      raise exception 'captain assignment required';
    end if;
    if existing_operation.completion_state is distinct from p_completion_state
       or existing_operation.notes is distinct from p_notes
       or existing_operation.incident_summary is distinct from v_incident_summary then
      raise exception 'leg completion evidence already recorded';
    end if;
    return existing_operation.ended_at;
  end if;
  if existing_operation.captain_assignment_id<>v_assignment_id then
    raise exception 'captain assignment required';
  end if;

  if target_leg.id<>v_outbound_id then
    select * into previous_operation from pace_v2.captain_leg_operations
    where confirmed_allocation_id=v_allocation_id and departure_id=v_outbound_id for update;
    if previous_operation.ended_at is null then raise exception 'leg transition out of order'; end if;
    if previous_operation.completion_state='incident' then
      raise exception 'incident-ended duty cannot start another leg; escalate to Site Admin';
    end if;
  end if;

  -- Persist the caller's immutable server evidence first. If any later legacy
  -- integration fails, the transaction rolls this write back with it.
  v_ended_at:=clock_timestamp();
  update pace_v2.captain_leg_operations
  set ended_at=v_ended_at,completion_state=p_completion_state,
      notes=p_notes,incident_summary=v_incident_summary,ended_by_user_id=auth.uid(),
      finalization_authorized=false
  where confirmed_allocation_id=v_allocation_id and departure_id=target_leg.id
    and ended_at is null;

  if target_leg.id=final_leg.id then
    perform allocation.id
    from pace_v2.confirmed_allocations allocation
    where allocation.departure_id=v_outbound_id and allocation.status='confirmed'
    order by allocation.id for update;

    select not exists(
      select 1
      from pace_v2.confirmed_allocations allocation
      left join pace_v2.captain_leg_operations operation
        on operation.confirmed_allocation_id=allocation.id
       and operation.departure_id=v_final_id
      where allocation.departure_id=v_outbound_id
        and allocation.status='confirmed'
        and operation.ended_at is null
    ) into v_all_allocations_finished;

    if v_all_allocations_finished then
      -- Every allocation owns independent voyage/settlement/feedback evidence.
      -- The outbound advisory lock plus ordered allocation row locks ensure the
      -- batch runs once; exact RPC retries return above without duplicating it.
      for v_finalization in
        select allocation.id as allocation_id,integration.assignment_id,
          integration.assignment_count,integration.captain_user_id,
          operation.completion_state,operation.notes,operation.incident_summary
        from pace_v2.confirmed_allocations allocation
        join pace_v2.captain_leg_operations operation
          on operation.confirmed_allocation_id=allocation.id
         and operation.departure_id=v_final_id and operation.ended_at is not null
        left join lateral(
          select candidate.assignment_id,candidate.captain_user_id,
            count(*) over() as assignment_count
          from (
            select distinct integration_assignment.id as assignment_id,
              integration_captain.auth_user_id as captain_user_id
            from pace_v2.captain_assignments integration_assignment
            join pace_v2.captains integration_captain
              on integration_captain.id=integration_assignment.captain_id
             and integration_captain.active
             and integration_captain.operator_id=allocation.operator_id
             and integration_captain.auth_user_id is not null
            join pace_v2.vehicles integration_vehicle
              on integration_vehicle.id=allocation.vehicle_id and integration_vehicle.active
            join pace_v2.captain_vehicle_types integration_eligibility
              on integration_eligibility.captain_id=integration_captain.id
             and integration_eligibility.vehicle_type_id=integration_vehicle.vehicle_type_id
             and integration_eligibility.active
            where integration_assignment.confirmed_allocation_id=allocation.id
              and integration_assignment.active
          ) candidate
          order by candidate.assignment_id
          limit 1
        ) integration on true
        where allocation.departure_id=v_outbound_id
          and allocation.status='confirmed'
        order by allocation.id
      loop
        if v_finalization.assignment_id is null
           or v_finalization.assignment_count<>1
           or v_finalization.captain_user_id is null then
          raise exception 'confirmed allocation has no active eligible integration assignment';
        end if;
        -- A completed leg may have been reassigned before the final shared
        -- allocation finishes. Its ended final-leg evidence authorizes this
        -- atomic, idempotent start-then-complete integration for the current
        -- assignment without violating the start-only operation row shape.
        update pace_v2.captain_leg_operations
        set finalization_authorized=true
        where confirmed_allocation_id=v_finalization.allocation_id
          and departure_id=v_final_id;
        perform set_config('request.jwt.claim.sub',v_finalization.captain_user_id::text,true);
        perform public.v2_captain_start_journey(
          p_captain_assignment_id=>v_finalization.assignment_id
        );
        perform public.v2_captain_complete_journey(
          p_captain_assignment_id=>v_finalization.assignment_id,
          p_completed_normally=>(v_finalization.completion_state='normal'),
          p_captain_notes=>v_finalization.notes,
          p_incident_flag=>(v_finalization.completion_state='incident'),
          p_incident_summary=>v_finalization.incident_summary
        );
        update pace_v2.captain_leg_operations
        set finalization_authorized=false
        where confirmed_allocation_id=v_finalization.allocation_id
          and departure_id=v_final_id;
      end loop;
      perform set_config('request.jwt.claim.sub',v_original_auth_user,true);
    end if;
  end if;
  return v_ended_at;
end $$;

revoke all on function public.v2_captain_start_leg(uuid,uuid) from public,anon,authenticated;
revoke all on function public.v2_captain_end_leg(uuid,text,text,text,uuid) from public,anon,authenticated;
grant execute on function public.v2_captain_start_leg(uuid,uuid) to authenticated;
grant execute on function public.v2_captain_end_leg(uuid,text,text,text,uuid) to authenticated;

notify pgrst,'reload schema';
