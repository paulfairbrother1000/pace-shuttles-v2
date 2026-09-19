-- A forced T-24 run before its real due time must not suppress the genuine run.
-- Reclaim only records whose execution began before scheduled_for and only once
-- the actual T-24 timestamp has arrived. A normal on-time completed run remains
-- idempotent and returns already_processed.
create or replace function pace_v2.process_departure_t24(
  p_departure_id uuid,
  p_engine_version text default 'scheduler-v1.5',
  p_force boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  d pace_v2.departures%rowtype;
  jr uuid;
  result jsonb;
  r record;
  consolidated_party_count integer:=0;
begin
  select * into d
  from pace_v2.departures
  where id=p_departure_id
  for update;

  if not found then raise exception 'Departure not found'; end if;

  if not p_force and now()<d.t24_ts then
    return jsonb_build_object('outcome','not_due');
  end if;

  insert into pace_v2.scheduled_job_runs(
    job_name,departure_id,phase,scheduled_for,engine_version
  ) values(
    'departure_window_processor',d.id,'t24',d.t24_ts,p_engine_version
  )
  on conflict (job_name,departure_id,phase,scheduled_for) do update
  set started_at=now(),
      completed_at=null,
      status='running',
      outcome='{}'::jsonb,
      failure_message=null,
      engine_version=excluded.engine_version
  where pace_v2.scheduled_job_runs.started_at < pace_v2.scheduled_job_runs.scheduled_for
    and now() >= pace_v2.scheduled_job_runs.scheduled_for
  returning id into jr;

  if jr is null then
    return jsonb_build_object('outcome','already_processed');
  end if;

  begin
    if exists (
      select 1
      from pace_v2.bookings b
      left join pace_v2.booking_allocations ba
        on ba.booking_id=b.id
       and ba.status in ('preliminary','confirmed')
       and ba.seats=b.seats
      left join pace_v2.vehicle_considerations vc
        on vc.id=ba.vehicle_consideration_id
       and vc.departure_id=d.id
       and vc.status='under_consideration'
       and vc.assigned_seats>=vc.normal_min_seats
       and vc.assigned_revenue_cents>=pace_v2.required_consideration_revenue_cents(
         vc.min_revenue_cents,
         vc.min_value_threshold_ratio,
         vc.below_minimum_operation_mode
       )
      where b.departure_id=d.id
        and b.status in ('booked','at_risk','confirmed')
      group by b.id
      having count(ba.id)<>1 or count(vc.id)<>1
    ) then
      update pace_v2.departures
      set status='at_risk',
          at_risk_reason='T-24 confirmation requires manual review: one or more booking parties are not covered by a viable vehicle.',
          updated_at=now()
      where id=d.id;

      update pace_v2.bookings
      set status='at_risk',updated_at=now()
      where departure_id=d.id and status in ('booked','confirmed');

      update pace_v2.departure_revenue_gap_rescues
      set status='cancelled',resolved_at=now(),
          resolution='T-24 reached with incomplete whole-party vehicle coverage; manual review required.'
      where departure_id=d.id and status='open';

      insert into pace_v2.allocation_decisions(
        departure_id,decision_type,engine_version,
        decision_reason_code,decision_reason_text,
        input_snapshot,candidate_snapshot,commercial_snapshot,
        quality_snapshot,fairness_snapshot
      ) values (
        d.id,'t24_manual_review',p_engine_version,
        'T24_INCOMPLETE_BOOKING_COVERAGE',
        'T-24 confirmation was not attempted because one or more whole booking parties were not allocated to a viable vehicle. Manual review is required.',
        jsonb_build_object('manual_review_required',true),
        coalesce((
          select jsonb_agg(jsonb_build_object(
            'booking_id',b.id,
            'booking_status',b.status,
            'allocated_consideration_id',ba.vehicle_consideration_id,
            'consideration_status',vc.status
          ) order by b.id)
          from pace_v2.bookings b
          left join pace_v2.booking_allocations ba
            on ba.booking_id=b.id
           and ba.status in ('preliminary','confirmed')
           and ba.seats=b.seats
          left join pace_v2.vehicle_considerations vc
            on vc.id=ba.vehicle_consideration_id
          where b.departure_id=d.id
            and b.status in ('booked','at_risk','confirmed')
        ),'[]'::jsonb),
        jsonb_build_object('customer_prices_changed',false),
        '{}'::jsonb,'{}'::jsonb
      );

      for r in
        select b.id
        from pace_v2.bookings b
        where b.departure_id=d.id
          and b.status in ('booked','at_risk','confirmed')
      loop
        perform pace_v2.queue_notification(
          null,r.id,d.id,'in_app','T24_CUSTOMER_ACTION_REQUIRED',
          'Important journey update',
          'Your journey requires manual review before it can be confirmed.',
          d.t24_ts
        );
      end loop;

      result:=jsonb_build_object(
        'outcome','at_risk_manual_review',
        'reason_code','T24_INCOMPLETE_BOOKING_COVERAGE',
        't24_consolidated_party_count',0
      );

      update pace_v2.scheduled_job_runs
      set status='completed',completed_at=now(),outcome=result
      where id=jr;

      return result;
    end if;

    consolidated_party_count:=pace_v2.consolidate_departure_fleet_t24(
      d.id,
      p_engine_version
    );

    -- Do not begin confirmation when an operator cannot provide one distinct,
    -- eligible captain for every simultaneous surviving vehicle. The deferred
    -- allocation constraint would otherwise abort the entire scheduler run.
    if exists (
      with required as (
        select vc.operator_id,v.vehicle_type_id,count(*)::integer vehicle_count
        from pace_v2.vehicle_considerations vc
        join pace_v2.vehicles v on v.id=vc.vehicle_id and v.active
        where vc.departure_id=d.id
          and vc.status='under_consideration'
          and vc.assigned_seats>0
        group by vc.operator_id,v.vehicle_type_id
      ), available as (
        select req.operator_id,req.vehicle_type_id,
          count(distinct cap.id)::integer captain_count
        from required req
        left join pace_v2.captains cap
          on cap.operator_id=req.operator_id and cap.active
        left join pace_v2.captain_vehicle_types cvt
          on cvt.captain_id=cap.id
         and cvt.vehicle_type_id=req.vehicle_type_id and cvt.active
        where cvt.captain_id is not null
        group by req.operator_id,req.vehicle_type_id
      )
      select 1
      from required req
      left join available av
        on av.operator_id=req.operator_id
       and av.vehicle_type_id=req.vehicle_type_id
      where coalesce(av.captain_count,0)<req.vehicle_count
    ) then
      update pace_v2.departures
      set status='at_risk',
          at_risk_reason='T-24 confirmation requires manual review: insufficient eligible captains for the surviving vehicles.',
          updated_at=now()
      where id=d.id;

      update pace_v2.bookings
      set status='at_risk',updated_at=now()
      where departure_id=d.id and status in ('booked','confirmed');

      insert into pace_v2.allocation_decisions(
        departure_id,decision_type,engine_version,
        decision_reason_code,decision_reason_text,
        input_snapshot,candidate_snapshot,commercial_snapshot,
        quality_snapshot,fairness_snapshot
      ) values (
        d.id,'t24_manual_review',p_engine_version,
        'T24_INSUFFICIENT_CAPTAINS',
        'T-24 confirmation was withheld because there were not enough distinct eligible captains for all simultaneous surviving vehicles.',
        jsonb_build_object('manual_review_required',true),
        coalesce((
          select jsonb_agg(jsonb_build_object(
            'consideration_id',vc.id,'operator_id',vc.operator_id,
            'vehicle_id',vc.vehicle_id,'assigned_seats',vc.assigned_seats
          ) order by vc.id)
          from pace_v2.vehicle_considerations vc
          where vc.departure_id=d.id
            and vc.status='under_consideration'
            and vc.assigned_seats>0
        ),'[]'::jsonb),
        jsonb_build_object('customer_prices_changed',false),
        '{}'::jsonb,'{}'::jsonb
      );

      for r in
        select b.id
        from pace_v2.bookings b
        where b.departure_id=d.id
          and b.status in ('booked','at_risk','confirmed')
      loop
        perform pace_v2.queue_notification(
          null,r.id,d.id,'in_app','T24_CUSTOMER_ACTION_REQUIRED',
          'Important journey update',
          'Your journey requires manual review before it can be confirmed.',
          d.t24_ts
        );
      end loop;

      result:=jsonb_build_object(
        'outcome','at_risk_manual_review',
        'reason_code','T24_INSUFFICIENT_CAPTAINS',
        't24_consolidated_party_count',consolidated_party_count
      );

      update pace_v2.scheduled_job_runs
      set status='completed',completed_at=now(),outcome=result
      where id=jr;

      return result;
    end if;

    select to_jsonb(x) || jsonb_build_object(
      't24_consolidated_party_count',consolidated_party_count
    )
    into result
    from pace_v2.confirm_departure_t24(
      d.id,
      p_force,
      p_engine_version
    ) x;

    for r in
      select distinct ca.operator_id
      from pace_v2.confirmed_allocations ca
      where ca.departure_id=d.id and ca.status='confirmed'
    loop
      perform pace_v2.queue_notification(
        r.operator_id,null,d.id,'in_app','T24_OPERATOR_CONFIRMED',
        'Journey confirmed',
        'Your vehicle has been confirmed for this journey.',d.t24_ts
      );
    end loop;

    for r in
      select b.id,d2.status as departure_status
      from pace_v2.bookings b
      join pace_v2.departures d2 on d2.id=b.departure_id
      where b.departure_id=d.id
        and b.status in ('booked','at_risk','confirmed')
    loop
      if r.departure_status='confirmed' then
        perform pace_v2.queue_notification(
          null,r.id,d.id,'in_app','T24_CUSTOMER_CONFIRMED',
          'Journey confirmed','Your Pace Shuttles journey is confirmed.',d.t24_ts
        );
      elsif r.departure_status in ('at_risk','cancelled') then
        perform pace_v2.queue_notification(
          null,r.id,d.id,'in_app','T24_CUSTOMER_ACTION_REQUIRED',
          'Important journey update',
          'Your journey could not be normally confirmed. Please review the latest Pace Shuttles update.',
          d.t24_ts
        );
      end if;
    end loop;

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
end;
$$;

comment on function pace_v2.process_departure_t24(uuid,text,boolean) is
  'Runs same-operator whole-party fleet consolidation before final T-24 confirmation and safely reclaims early forced runs at the genuine due time.';

revoke all on function pace_v2.process_departure_t24(uuid,text,boolean)
  from public,anon,authenticated,service_role;
