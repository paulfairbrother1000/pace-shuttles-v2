-- Preserve completed passenger parties on paired returns and finalize both physical legs.
CREATE OR REPLACE FUNCTION public.v2_captain_end_leg(p_departure_id uuid, p_completion_state text, p_notes text, p_incident_summary text, p_confirmed_allocation_id uuid DEFAULT NULL::uuid)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      -- Finalization is authorized only after every confirmed boat has ended.
      -- Keep physical leg timestamps separate from round-trip completion.
      update pace_v2.captain_leg_operations
      set finalization_authorized=true
      where departure_id=v_final_id and ended_at is not null
        and confirmed_allocation_id in (
          select id from pace_v2.confirmed_allocations where departure_id=v_outbound_id
        );
      update pace_v2.voyage_logs voyage
      set actual_departure_ts=outbound_operation.started_at,
          actual_arrival_ts=final_operation.ended_at,
          completion_submitted_at=coalesce(voyage.completion_submitted_at,final_operation.ended_at),
          locked_at=coalesce(voyage.locked_at,final_operation.ended_at)
      from pace_v2.confirmed_allocations allocation
      join pace_v2.captain_leg_operations outbound_operation
        on outbound_operation.confirmed_allocation_id=allocation.id
       and outbound_operation.departure_id=v_outbound_id
      join pace_v2.captain_leg_operations final_operation
        on final_operation.confirmed_allocation_id=allocation.id
       and final_operation.departure_id=v_final_id
      where voyage.confirmed_allocation_id=allocation.id
        and allocation.departure_id=v_outbound_id and allocation.status='completed';
      update pace_v2.confirmed_allocations allocation
      set completed_at=operation.ended_at
      from pace_v2.captain_leg_operations operation
      where operation.confirmed_allocation_id=allocation.id and operation.departure_id=v_final_id
        and allocation.departure_id=v_outbound_id and allocation.status='completed';
      update pace_v2.departures departure
      set status='completed',actual_departure_ts=timing.started_at,
          actual_arrival_ts=timing.ended_at,
          completed_at=(select max(ended_at) from pace_v2.captain_leg_operations
            where departure_id=v_final_id),
          closed_at=null,closure_reason=null,at_risk_reason=null
      from (
        select operation.departure_id,min(operation.started_at) started_at,
               max(operation.ended_at) ended_at
        from pace_v2.captain_leg_operations operation
        join pace_v2.confirmed_allocations allocation
          on allocation.id=operation.confirmed_allocation_id
         and allocation.departure_id=v_outbound_id and allocation.status='completed'
        where operation.departure_id in(v_outbound_id,v_final_id)
        group by operation.departure_id
      ) timing
      where departure.id=timing.departure_id;
      update pace_v2.captain_leg_operations
      set finalization_authorized=false
      where departure_id=v_final_id and finalization_authorized
        and confirmed_allocation_id in (
          select id from pace_v2.confirmed_allocations where departure_id=v_outbound_id
        );
      perform set_config('request.jwt.claim.sub',v_original_auth_user,true);
    end if;
  end if;
  -- Evaluate deferred captain constraints while this authorized RPC still owns
  -- its privileged context. No authenticated helper grant is required.
  SET CONSTRAINTS pace_v2.confirmed_allocations_require_eligible_captain,
    pace_v2.captain_assignments_preserve_eligible_allocation_captain IMMEDIATE;
  return v_ended_at;
end $function$
;
CREATE OR REPLACE FUNCTION public.v2_system_reconcile_empty_paired_returns(p_limit integer DEFAULT 100)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_count integer;
begin
  with targets as (
    select d.id
    from pace_v2.departures d
    where d.is_commercial=false
      and d.leg_number=2
      and d.journey_pair_id is not null
      and d.status not in('completed','cancelled','closed_unrecorded')
      and d.actual_arrival_ts is null
      and coalesce(d.scheduled_arrival_ts,d.scheduled_departure_ts+interval '8 hours')
          +interval '24 hours' <= now()
      and not exists (
        select 1
        from pace_v2.departures paired
        join pace_v2.bookings b on b.departure_id=paired.id
        where paired.journey_pair_id=d.journey_pair_id
          and b.status in('booked','at_risk','confirmed','completed')
      )
    order by d.scheduled_departure_ts,d.id
    limit greatest(1,least(coalesce(p_limit,100),1000))
    for update skip locked
  )
  update pace_v2.departures d
  set status='cancelled',
      cancelled_reason='Closed after departure — no paired bookings.',
      at_risk_reason=null
  from targets t where d.id=t.id;
  get diagnostics v_count=row_count;
  return v_count;
end
$function$
;
CREATE OR REPLACE FUNCTION public.v2_system_run_scheduled_operations(p_t72_limit integer DEFAULT 50, p_t24_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pace_v2'
AS $function$
declare
  r record;
  v_t72 integer:=0;
  v_t24 integer:=0;
  v_failed integer:=0;
  v_generated integer:=0;
  v_past_cancelled integer:=0;
  v_closed_count integer:=0;
  v_generation_date date;
  v_result jsonb;
begin
  with horizon_dates as (
    select generated_at::date as service_date
    from generate_series(current_date+340,current_date+380,interval '1 day') generated_at
  )
  select h.service_date into v_generation_date
  from horizon_dates h
  where exists(
    select 1 from pace_v2.services s
    where s.active
      and (s.valid_from is null or s.valid_from<=h.service_date)
      and (s.valid_to is null or s.valid_to>=h.service_date)
      and extract(isodow from h.service_date)::smallint=any(s.days_of_week)
      and (
        s.recurrence_interval_weeks=1 or s.recurrence_anchor_date is null
        or floor((h.service_date-s.recurrence_anchor_date)::numeric/7)::integer
           % s.recurrence_interval_weeks=0
      )
      and not exists(
        select 1 from pace_v2.departures d
        where d.service_id=s.id and d.local_departure_date=h.service_date
      )
  )
  order by h.service_date
  limit 1;

  if v_generation_date is not null then
    select count(*) filter(where g.inserted) into v_generated
    from pace_v2.generate_departures(v_generation_date,v_generation_date) g;
  end if;

  for r in
    select d.id from pace_v2.departures d
    where d.is_commercial
      and d.t72_ts<=now() and d.t24_ts>now()
      and d.status not in('completed','cancelled','closed_unrecorded','confirmed')
      and not exists(
        select 1 from pace_v2.scheduled_job_runs j
        where j.departure_id=d.id and j.phase='t72'
      )
    order by d.t72_ts
    limit greatest(1,least(coalesce(p_t72_limit,50),200))
  loop
    begin
      v_result:=pace_v2.process_departure_t72(r.id,'cron-v1.3',false);
      v_t72:=v_t72+1;
    exception when others then
      v_failed:=v_failed+1;
    end;
  end loop;

  for r in
    select d.id from pace_v2.departures d
    where d.is_commercial
      and d.t24_ts<=now()
      and d.status not in('completed','cancelled','closed_unrecorded','confirmed')
      and not exists(
        select 1 from pace_v2.scheduled_job_runs j
        where j.departure_id=d.id and j.phase='t24'
      )
    order by d.t24_ts
    limit greatest(1,least(coalesce(p_t24_limit,50),200))
  loop
    begin
      v_result:=pace_v2.process_departure_t24(r.id,'cron-v1.3',false);
      v_t24:=v_t24+1;
    exception when others then
      v_failed:=v_failed+1;
    end;
  end loop;

  with targets as (
    select d.id from pace_v2.departures d
    where d.is_commercial
      and d.status not in('completed','cancelled','closed_unrecorded')
      and coalesce(d.scheduled_arrival_ts,d.scheduled_departure_ts+interval '8 hours')
          +interval '24 hours'<=now()
      and not exists(
        select 1 from pace_v2.bookings b
        where b.departure_id=d.id and b.status in('booked','at_risk','confirmed')
      )
    order by d.scheduled_departure_ts
    limit 100
  )
  update pace_v2.departures d
  set status='cancelled',
      cancelled_reason=coalesce(d.cancelled_reason,'Closed after departure — no bookings.'),
      at_risk_reason=null
  from targets t where d.id=t.id;
  get diagnostics v_past_cancelled=row_count;

  with targets as (
    select d.id from pace_v2.departures d
    where d.status not in('completed','cancelled','closed_unrecorded')
      and d.actual_arrival_ts is null
      and coalesce(d.scheduled_arrival_ts,d.scheduled_departure_ts+interval '8 hours')
          +interval '24 hours'<=now()
      and (
        (d.is_commercial and exists(
          select 1 from pace_v2.bookings b
          where b.departure_id=d.id and b.status in('booked','at_risk','confirmed')
        ))
        or (not d.is_commercial and d.journey_pair_id is not null and exists(
          select 1
          from pace_v2.departures paired
          join pace_v2.bookings b on b.departure_id=paired.id
          where paired.journey_pair_id=d.journey_pair_id
            and b.status in('booked','at_risk','confirmed','completed')
        ))
      )
    order by d.scheduled_departure_ts
    limit 100
  )
  update pace_v2.departures d
  set status='closed_unrecorded'::pace_v2.departure_status,
      closed_at=now(),
      closure_reason='Closed — travel outcome unrecorded',
      at_risk_reason=null
  from targets t where d.id=t.id;
  get diagnostics v_closed_count=row_count;

  return jsonb_build_object(
    'generated_departures',v_generated,
    'generation_date',v_generation_date,
    't72_processed',v_t72,
    't24_processed',v_t24,
    'past_empty_cancelled',v_past_cancelled,
    'closed_unrecorded',v_closed_count,
    'failed',v_failed,
    'ran_at',now()
  );
end
$function$
;
