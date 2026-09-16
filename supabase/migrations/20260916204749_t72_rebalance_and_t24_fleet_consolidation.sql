-- Allocation windows:
-- * normal-price progressive filling before T-72;
-- * whole-party viability rebalancing at T-72;
-- * surviving-vehicle discount competition after T-72; and
-- * same-operator fleet consolidation immediately before T-24 confirmation.

alter table pace_v2.vehicle_considerations
  add column if not exists t24_consolidated_at timestamptz,
  add column if not exists t24_resolution_reason text;

create or replace function pace_v2.required_consideration_revenue_cents(
  p_min_revenue_cents integer,
  p_min_value_threshold_ratio numeric,
  p_below_minimum_operation_mode text
)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case
    when p_below_minimum_operation_mode <> 'never'
     and p_min_value_threshold_ratio is not null
      then ceil(p_min_revenue_cents * p_min_value_threshold_ratio)::integer
    else p_min_revenue_cents
  end;
$$;

revoke all on function pace_v2.required_consideration_revenue_cents(integer,numeric,text)
  from public,anon,authenticated,service_role;

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

  if now()>=d.t24_ts or d.status in ('confirmed','active','completed','cancelled','closed_unrecorded') then
    return;
  end if;

  perform pace_v2.refresh_vehicle_considerations(
    p_departure_id,
    'live-progressive-v0.7'
  );
  perform pace_v2.refresh_live_consideration_states(p_departure_id);

  if d.t72_ts > now() then
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
      join pace_v2.vehicles v on v.id=vc.vehicle_id
      join pace_v2.operators o on o.id=vc.operator_id
      where vc.departure_id=p_departure_id
        and vc.status not in(
          'withdrawn','discarded_t72','under_consideration',
          'confirmed','replaced','cancelled'
        )
    ), target as (
      select min(o.seq)::integer as target_seq
      from ordered o
      where not o.min_met
        and o.remaining_capacity>=p_party_size
    ), candidates as (
      select
        o.*,
        'PRE_T72_NEXT_MINIMUM'::text as stage
      from ordered o cross join target t
      where t.target_seq is not null
        and o.seq=t.target_seq
        and o.remaining_capacity>=p_party_size

      union all

      select
        o.*,
        'PRE_T72_FULL_PRICE_CAPACITY'::text as stage
      from ordered o cross join target t
      where t.target_seq is null
        and o.min_met
        and o.remaining_capacity>=p_party_size
    ), ranked as (
      select c.*,
        row_number() over(
          order by c.normal_price,c.quality_score desc,c.seq,c.consideration_id
        )::integer as offer_rank
      from candidates c
    )
    select
      r.offer_rank,r.consideration_id,r.vehicle_id,r.operator_id,
      r.vehicle_name,r.operator_name,r.seq,r.stage,r.assigned_seats,
      r.remaining_capacity,r.normal_min_seats,r.max_seats,r.min_met,
      false,false,r.normal_price,r.normal_price,r.discount_bps,r.quality_score
    from ranked r
    order by r.offer_rank;

    return;
  end if;

  return query
  with candidates as (
    select
      vc.id as consideration_id,
      vc.vehicle_id,
      vc.operator_id,
      v.name as vehicle_name,
      o.name as operator_name,
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
    join pace_v2.vehicles v on v.id=vc.vehicle_id
    join pace_v2.operators o on o.id=vc.operator_id
    where vc.departure_id=p_departure_id
      and vc.status='under_consideration'
      and vc.assigned_seats>=vc.normal_min_seats
  ), priced as (
    select c.*,
      c.discount_enabled and c.discount_bps>0 as use_discount,
      case
        when c.discount_enabled and c.discount_bps>0
          then ceil(c.normal_price::numeric*(10000-c.discount_bps)/10000)::integer
        else c.normal_price
      end as offer_price
    from candidates c
    where c.remaining_capacity>=p_party_size
  ), ranked as (
    select p.*,
      row_number() over(
        order by p.offer_price,p.quality_score desc,p.seq,p.consideration_id
      )::integer as offer_rank
    from priced p
  )
  select
    r.offer_rank,r.consideration_id,r.vehicle_id,r.operator_id,
    r.vehicle_name,r.operator_name,r.seq,
    'POST_T72_DISCOUNT_COMPETITION'::text,
    r.assigned_seats,r.remaining_capacity,r.normal_min_seats,r.max_seats,
    true,true,r.use_discount,r.normal_price,r.offer_price,
    r.discount_bps,r.quality_score
  from ranked r
  order by r.offer_rank;
end;
$$;

-- Candidate generation is reached only through the public quote wrappers.
-- It refreshes consideration state, so it must never be a directly callable
-- client RPC.
revoke all on function pace_v2.get_live_party_offer_candidates(uuid,integer)
  from public,anon,authenticated,service_role;
revoke all on function pace_v2.get_live_party_offer(uuid,integer)
  from public,anon,authenticated,service_role;
revoke all on function pace_v2.refresh_vehicle_considerations(uuid,text)
  from public,anon,authenticated,service_role;
revoke all on function pace_v2.refresh_live_consideration_states(uuid)
  from public,anon,authenticated,service_role;
revoke all on function pace_v2.refresh_consideration_totals(uuid)
  from public,anon,authenticated,service_role;

-- These lifecycle functions are internal implementation details. The scheduler
-- reaches them through the authenticated public system wrapper, whose owner
-- retains the ability to execute them after these grants are removed.
revoke all on function pace_v2.process_departure_t72(uuid,text,boolean)
  from public,anon,authenticated,service_role;

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
  with recursive
  active_bookings as (
    select
      b.id,
      b.seats,
      b.total_price_cents,
      ba.vehicle_consideration_id as current_consideration_id,
      case
        when b.commercial_snapshot#>>'{quote_snapshot,discount_applied}'='true'
          then ba.vehicle_consideration_id
        else null::uuid
      end as locked_consideration_id
    from pace_v2.bookings b
    join pace_v2.booking_allocations ba
      on ba.booking_id=b.id
     and ba.status in ('preliminary','confirmed')
     and ba.seats=b.seats
    join pace_v2.vehicle_considerations current_vehicle
      on current_vehicle.id=ba.vehicle_consideration_id
     and current_vehicle.operator_id=p_operator_id
     and current_vehicle.departure_id=p_departure_id
     and current_vehicle.status='under_consideration'
    where b.departure_id=p_departure_id
      and b.status in ('booked','at_risk','confirmed')
  ), bookings as (
    select ab.*,
      row_number() over(
        order by (ab.locked_consideration_id is not null) desc,
                 ab.seats desc,ab.total_price_cents desc,ab.id
      )::integer as booking_no
    from active_bookings ab
  ), vehicles as (
    select
      vc.id,vc.max_seats,vc.normal_min_seats,
      pace_v2.required_consideration_revenue_cents(
        vc.min_revenue_cents,
        vc.min_value_threshold_ratio,
        vc.below_minimum_operation_mode
      ) as required_revenue_cents,
      vc.assigned_seats as starting_assigned_seats,
      vc.quality_score_snapshot
    from pace_v2.vehicle_considerations vc
    where vc.departure_id=p_departure_id
      and vc.operator_id=p_operator_id
      and vc.status='under_consideration'
      and vc.assigned_seats>0
  ), limits as (
    select
      (select count(*) from bookings)::integer as booking_count,
      (select count(*) from vehicles)::integer as vehicle_count
  ), search(
    booking_no,seat_totals,revenue_totals,assignments,
    moved_parties,moved_seats
  ) as (
    select
      0,'{}'::jsonb,'{}'::jsonb,array[]::uuid[],0,0
    from limits
    where booking_count>=1
      and vehicle_count between 2 and 6
      and power(vehicle_count::numeric,booking_count::numeric)<=100000

    union all

    select
      s.booking_no+1,
      s.seat_totals || jsonb_build_object(
        v.id::text,
        coalesce((s.seat_totals->>v.id::text)::integer,0)+b.seats
      ),
      s.revenue_totals || jsonb_build_object(
        v.id::text,
        coalesce((s.revenue_totals->>v.id::text)::bigint,0)+b.total_price_cents
      ),
      s.assignments || v.id,
      s.moved_parties+
        case when b.current_consideration_id=v.id then 0 else 1 end,
      s.moved_seats+
        case when b.current_consideration_id=v.id then 0 else b.seats end
    from search s
    join bookings b on b.booking_no=s.booking_no+1
    join vehicles v
      on (b.locked_consideration_id is null or b.locked_consideration_id=v.id)
     and coalesce((s.seat_totals->>v.id::text)::integer,0)+b.seats<=v.max_seats
  ), valid_plans as (
    select
      s.*,
      (
        select count(*)::integer
        from vehicles v
        where coalesce((s.seat_totals->>v.id::text)::integer,0)>0
      ) as used_vehicle_count,
      (
        select coalesce(sum(v.max_seats),0)
        from vehicles v
        where coalesce((s.seat_totals->>v.id::text)::integer,0)>0
      ) as retained_capacity,
      (
        select coalesce(sum(v.quality_score_snapshot),0)
        from vehicles v
        where coalesce((s.seat_totals->>v.id::text)::integer,0)>0
      ) as retained_quality
    from search s cross join limits l
    where s.booking_no=l.booking_count
      and not exists (
        select 1
        from vehicles v
        where coalesce((s.seat_totals->>v.id::text)::integer,0)>0
          and (
            coalesce((s.seat_totals->>v.id::text)::integer,0)<v.normal_min_seats
            or coalesce((s.revenue_totals->>v.id::text)::bigint,0)<v.required_revenue_cents
          )
      )
  ), winning_plan as (
    select vp.*,l.vehicle_count
    from valid_plans vp cross join limits l
    where vp.used_vehicle_count<l.vehicle_count
    order by vp.used_vehicle_count,
             vp.moved_seats,
             vp.moved_parties,
             vp.retained_capacity desc,
             vp.retained_quality desc,
             vp.assignments::text
    limit 1
  )
  select
    b.id,
    wp.assignments[b.booking_no],
    b.locked_consideration_id is not null,
    wp.vehicle_count,
    wp.used_vehicle_count
  from winning_plan wp
  join bookings b on true
  order by b.booking_no;
$$;

revoke all on function pace_v2.plan_t24_operator_consolidation(uuid,uuid)
  from public,anon,authenticated,service_role;

create or replace function pace_v2.consolidate_operator_fleet_t24(
  p_departure_id uuid,
  p_operator_id uuid,
  p_engine_version text default 't24-v0.7'
)
returns integer
language plpgsql
security definer
set search_path=''
as $$
declare
  booking_count integer;
  planned_count integer;
  existing_vehicle_count integer;
  planned_vehicle_count integer;
  moved_count integer:=0;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_departure_id::text,3));

  select count(*) into booking_count
  from pace_v2.bookings b
  join pace_v2.booking_allocations ba
    on ba.booking_id=b.id
   and ba.status in ('preliminary','confirmed')
   and ba.seats=b.seats
  join pace_v2.vehicle_considerations vc
    on vc.id=ba.vehicle_consideration_id
   and vc.departure_id=p_departure_id
   and vc.operator_id=p_operator_id
   and vc.status='under_consideration'
  where b.departure_id=p_departure_id
    and b.status in ('booked','at_risk','confirmed');

  if booking_count>0 and (
    select power(count(distinct vc.id)::numeric,booking_count::numeric)>100000
           or count(distinct vc.id)>6
    from pace_v2.vehicle_considerations vc
    where vc.departure_id=p_departure_id
      and vc.operator_id=p_operator_id
      and vc.status='under_consideration'
      and vc.assigned_seats>0
  ) then
    raise exception
      'T-24 allocation planner limit exceeded for departure % operator % (% bookings); manual review required',
      p_departure_id,p_operator_id,booking_count;
  end if;

  if exists (
    select 1
    from pace_v2.bookings b
    left join pace_v2.booking_allocations ba
      on ba.booking_id=b.id
     and ba.status in ('preliminary','confirmed')
     and ba.seats=b.seats
    where b.departure_id=p_departure_id
      and b.status in ('booked','at_risk','confirmed')
    group by b.id
    having count(ba.id)<>1
  ) then
    return 0;
  end if;

  if booking_count=0 then return 0; end if;

  drop table if exists pg_temp.pace_t24_operator_plan;
  create temporary table pace_t24_operator_plan on commit drop as
  select *
  from pace_v2.plan_t24_operator_consolidation(
    p_departure_id,
    p_operator_id
  );

  select count(*),max(plan.existing_vehicle_count),max(plan.planned_vehicle_count)
  into planned_count,existing_vehicle_count,planned_vehicle_count
  from pg_temp.pace_t24_operator_plan plan;

  if planned_count<>booking_count
     or planned_vehicle_count is null
     or planned_vehicle_count>=existing_vehicle_count then
    return 0;
  end if;

  update pace_v2.booking_allocations ba
  set
    vehicle_consideration_id=plan.consideration_id,
    vehicle_id=vc.vehicle_id,
    allocation_reason='T-24 same-operator fleet consolidation'
  from pg_temp.pace_t24_operator_plan plan
  join pace_v2.vehicle_considerations vc
    on vc.id=plan.consideration_id
  where ba.booking_id=plan.booking_id
    and ba.status in ('preliminary','confirmed')
    and ba.vehicle_consideration_id is distinct from plan.consideration_id;

  get diagnostics moved_count=row_count;

  update pace_v2.bookings b
  set preliminary_vehicle_id=vc.vehicle_id,updated_at=now()
  from pg_temp.pace_t24_operator_plan plan
  join pace_v2.vehicle_considerations vc
    on vc.id=plan.consideration_id
  where b.id=plan.booking_id
    and b.preliminary_vehicle_id is distinct from vc.vehicle_id;

  perform pace_v2.refresh_consideration_totals(p_departure_id);

  update pace_v2.vehicle_considerations vc
  set
    status='replaced',
    t24_consolidated_at=now(),
    t24_resolution_reason='Not required — operator fleet consolidated at T-24.',
    updated_at=now()
  where vc.departure_id=p_departure_id
    and vc.operator_id=p_operator_id
    and vc.status='under_consideration'
    and vc.assigned_seats=0;

  insert into pace_v2.allocation_decisions(
    departure_id,decision_type,engine_version,
    decision_reason_code,decision_reason_text,
    selected_operator_id,input_snapshot,candidate_snapshot,
    commercial_snapshot,quality_snapshot,fairness_snapshot
  )
  values(
    p_departure_id,'t24_operator_fleet_consolidation',p_engine_version,
    'T24_OPERATOR_FLEET_CONSOLIDATED',
    'Not required — operator fleet consolidated at T-24.',
    p_operator_id,
    jsonb_build_object(
      'existing_vehicle_count',existing_vehicle_count,
      'planned_vehicle_count',planned_vehicle_count,
      'moved_party_count',moved_count
    ),
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'booking_id',plan.booking_id,
        'consideration_id',plan.consideration_id,
        'locked_to_discount_vehicle',plan.locked_to_discount_vehicle
      ) order by plan.booking_id)
      from pg_temp.pace_t24_operator_plan plan
    ),'[]'::jsonb),
    jsonb_build_object('customer_prices_changed',false),
    '{}'::jsonb,'{}'::jsonb
  );

  return moved_count;
end;
$$;

revoke all on function pace_v2.consolidate_operator_fleet_t24(uuid,uuid,text)
  from public,anon,authenticated,service_role;

create or replace function pace_v2.consolidate_departure_fleet_t24(
  p_departure_id uuid,
  p_engine_version text default 't24-v0.7'
)
returns integer
language plpgsql
security definer
set search_path=''
as $$
declare
  operator_row record;
  total_moved integer:=0;
begin
  if not exists (
    select 1
    from pace_v2.departures d
    where d.id=p_departure_id
      and d.status='under_consideration'
  ) or exists (
    select 1
    from pace_v2.departure_revenue_gap_rescues rescue
    where rescue.departure_id=p_departure_id
      and rescue.status='open'
  ) then
    return 0;
  end if;

  for operator_row in
    select vc.operator_id
    from pace_v2.vehicle_considerations vc
    where vc.departure_id=p_departure_id
      and vc.status='under_consideration'
      and vc.assigned_seats>0
    group by vc.operator_id
    having count(*)>1
    order by vc.operator_id
  loop
    total_moved:=total_moved+pace_v2.consolidate_operator_fleet_t24(
      p_departure_id,
      operator_row.operator_id,
      p_engine_version
    );
  end loop;

  return total_moved;
end;
$$;

revoke all on function pace_v2.consolidate_departure_fleet_t24(uuid,text)
  from public,anon,authenticated,service_role;

create or replace function pace_v2.process_departure_t24(
  p_departure_id uuid,
  p_engine_version text default 'scheduler-v1.4',
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
  on conflict do nothing
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
  'Runs same-operator whole-party fleet consolidation before final T-24 confirmation.';

revoke all on function pace_v2.process_departure_t24(uuid,text,boolean)
  from public,anon,authenticated,service_role;
revoke all on function pace_v2.confirm_departure_t24(uuid,boolean,text)
  from public,anon,authenticated,service_role;

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
  with recursive
  active_bookings as (
    select
      b.id,
      b.seats,
      b.total_price_cents,
      current_allocation.vehicle_consideration_id as current_consideration_id,
      case
        when b.commercial_snapshot#>>'{quote_snapshot,discount_applied}'='true'
          then coalesce(
            nullif(
              b.commercial_snapshot#>>'{quote_snapshot,vehicle_consideration_id}',
              ''
            )::uuid,
            current_allocation.vehicle_consideration_id
          )
        else null::uuid
      end as locked_consideration_id
    from pace_v2.bookings b
    join lateral (
      select ba.vehicle_consideration_id
      from pace_v2.booking_allocations ba
      where ba.booking_id=b.id
        and ba.status in ('preliminary','confirmed')
        and ba.seats=b.seats
      order by ba.allocated_at desc,ba.id
      limit 1
    ) current_allocation on true
    where b.departure_id=p_departure_id
      and b.status in ('booked','at_risk','confirmed')
  ), bookings as (
    select ab.*,
      row_number() over(
        order by (ab.locked_consideration_id is not null) desc,
                 ab.seats desc,ab.total_price_cents desc,ab.id
      )::integer as booking_no
    from active_bookings ab
  ), vehicles as (
    select
      vc.id,
      vc.max_seats,
      vc.normal_min_seats,
      pace_v2.required_consideration_revenue_cents(
        vc.min_revenue_cents,
        vc.min_value_threshold_ratio,
        vc.below_minimum_operation_mode
      ) as required_revenue_cents,
      vc.quality_score_snapshot,
      vc.normal_base_seat_price_cents
    from pace_v2.vehicle_considerations vc
    where vc.departure_id=p_departure_id
      and vc.status not in(
        'withdrawn','discarded_t72','confirmed','replaced','cancelled'
      )
  ), limits as (
    select
      (select count(*) from bookings)::integer as booking_count,
      (select count(*) from vehicles)::integer as vehicle_count
  ), search(
    booking_no,seat_totals,revenue_totals,assignments,moved_parties
  ) as (
    select
      0,'{}'::jsonb,'{}'::jsonb,array[]::uuid[],0
    from limits
    where booking_count>=1
      and vehicle_count between 1 and 6
      and power(vehicle_count::numeric,booking_count::numeric)<=100000

    union all

    select
      s.booking_no+1,
      s.seat_totals || jsonb_build_object(
        v.id::text,
        coalesce((s.seat_totals->>v.id::text)::integer,0)+b.seats
      ),
      s.revenue_totals || jsonb_build_object(
        v.id::text,
        coalesce((s.revenue_totals->>v.id::text)::bigint,0)+b.total_price_cents
      ),
      s.assignments || v.id,
      s.moved_parties +
        case when b.current_consideration_id=v.id then 0 else 1 end
    from search s
    join bookings b on b.booking_no=s.booking_no+1
    join vehicles v
      on (b.locked_consideration_id is null or b.locked_consideration_id=v.id)
     and coalesce((s.seat_totals->>v.id::text)::integer,0)+b.seats<=v.max_seats
  ), valid_plans as (
    select
      s.*,
      (
        select count(*)::integer
        from vehicles v
        where coalesce((s.seat_totals->>v.id::text)::integer,0)>0
      ) as used_vehicle_count,
      (
        select coalesce(sum(v.quality_score_snapshot),0)
        from vehicles v
        where coalesce((s.seat_totals->>v.id::text)::integer,0)>0
      ) as used_quality,
      (
        select coalesce(sum(v.normal_base_seat_price_cents),0)
        from vehicles v
        where coalesce((s.seat_totals->>v.id::text)::integer,0)>0
      ) as used_normal_price
    from search s cross join limits l
    where s.booking_no=l.booking_count
      and not exists (
        select 1
        from vehicles v
        where coalesce((s.seat_totals->>v.id::text)::integer,0)>0
          and (
            coalesce((s.seat_totals->>v.id::text)::integer,0)<v.normal_min_seats
            or coalesce((s.revenue_totals->>v.id::text)::bigint,0)<v.required_revenue_cents
          )
      )
  ), winning_plan as (
    select vp.*
    from valid_plans vp
    order by vp.used_vehicle_count desc,
             vp.moved_parties,
             vp.used_quality desc,
             vp.used_normal_price,
             vp.assignments::text
    limit 1
  )
  select
    b.id,
    wp.assignments[b.booking_no],
    b.locked_consideration_id is not null
  from winning_plan wp
  join bookings b on true
  order by b.booking_no;
$$;

revoke all on function pace_v2.plan_t72_whole_party_allocations(uuid)
  from public,anon,authenticated,service_role;

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
language plpgsql
security definer
set search_path=''
as $$
declare
  d pace_v2.departures%rowtype;
  booking_count integer;
  seats_total integer;
  revenue_total integer;
  viable_count integer;
  planned_count integer;
  moved_count integer := 0;
  uncovered_count integer;
  plan_mode text := 'exact_whole_party';
  rescue record;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_departure_id::text,2));

  select * into d
  from pace_v2.departures
  where id=p_departure_id
  for update;

  if not found then
    raise exception 'Departure % not found',p_departure_id;
  end if;

  if now()<d.t72_ts then
    raise exception 'T-72 evaluation is not due for departure %',p_departure_id;
  end if;

  if d.status='confirmed' then
    select count(*) into viable_count
    from pace_v2.confirmed_allocations
    where departure_id=p_departure_id and status='confirmed';

    select count(*),coalesce(sum(seats),0)::integer,
           coalesce(sum(total_price_cents),0)::integer
    into booking_count,seats_total,revenue_total
    from pace_v2.bookings
    where departure_id=p_departure_id and status='confirmed';

    return query
    select 'already_confirmed'::text,viable_count,seats_total,revenue_total,0;
    return;
  end if;

  if d.status in ('completed','cancelled','closed_unrecorded') then
    return query
    select ('already_'||d.status::text)::text,0,
      coalesce((select sum(b.seats)::integer from pace_v2.bookings b
                where b.departure_id=p_departure_id),0),
      coalesce((select sum(b.total_price_cents)::integer from pace_v2.bookings b
                where b.departure_id=p_departure_id),0),
      null::integer;
    return;
  end if;

  perform pace_v2.refresh_vehicle_considerations(p_departure_id,p_engine_version);
  perform pace_v2.refresh_consideration_totals(p_departure_id);

  select count(*),coalesce(sum(b.seats),0)::integer,
         coalesce(sum(b.total_price_cents),0)::integer
  into booking_count,seats_total,revenue_total
  from pace_v2.bookings b
  where b.departure_id=p_departure_id
    and b.status in ('booked','at_risk','confirmed');

  if booking_count=0 then
    raise exception
      'Departure % has no bookings; use evaluate_t72_zero_booking()',
      p_departure_id;
  end if;

  if exists (
    select 1
    from pace_v2.bookings b
    where b.departure_id=p_departure_id
      and b.status in ('booked','at_risk','confirmed')
      and (
        select count(*)
        from pace_v2.booking_allocations ba
        where ba.booking_id=b.id
          and ba.status in ('preliminary','confirmed')
          and ba.seats=b.seats
      )<>1
  ) then
    raise exception
      'One or more bookings on departure % do not have exactly one whole-party active allocation',
      p_departure_id;
  end if;

  if (
    select count(*)>6
           or power(count(*)::numeric,booking_count::numeric)>100000
    from pace_v2.vehicle_considerations vc
    where vc.departure_id=p_departure_id
      and vc.status not in(
        'withdrawn','discarded_t72','confirmed','replaced','cancelled'
      )
  ) then
    raise exception
      'T-72 allocation planner limit exceeded for departure % (% bookings); manual review required',
      p_departure_id,booking_count;
  end if;

  drop table if exists pg_temp.pace_t72_allocation_plan;
  create temporary table pace_t72_allocation_plan on commit drop as
  select *
  from pace_v2.plan_t72_whole_party_allocations(p_departure_id);

  select count(*) into planned_count
  from pg_temp.pace_t72_allocation_plan;

  if planned_count=booking_count then
    update pace_v2.booking_allocations ba
    set
      vehicle_consideration_id=plan.consideration_id,
      vehicle_id=vc.vehicle_id,
      allocation_reason='T-72 whole-party viability reallocation'
    from pg_temp.pace_t72_allocation_plan plan
    join pace_v2.vehicle_considerations vc
      on vc.id=plan.consideration_id
    where ba.booking_id=plan.booking_id
      and ba.status in ('preliminary','confirmed')
      and ba.vehicle_consideration_id is distinct from plan.consideration_id;

    get diagnostics moved_count=row_count;

    update pace_v2.bookings b
    set preliminary_vehicle_id=vc.vehicle_id,updated_at=now()
    from pg_temp.pace_t72_allocation_plan plan
    join pace_v2.vehicle_considerations vc
      on vc.id=plan.consideration_id
    where b.id=plan.booking_id
      and b.preliminary_vehicle_id is distinct from vc.vehicle_id;
  else
    plan_mode := 'no_feasible_whole_party_plan';
  end if;

  perform pace_v2.refresh_consideration_totals(p_departure_id);

  update pace_v2.vehicle_considerations vc
  set
    status='under_consideration',
    under_consideration_at=coalesce(vc.under_consideration_at,now()),
    t72_discarded_at=null,
    updated_at=now()
  where vc.departure_id=p_departure_id
    and vc.status not in ('withdrawn','confirmed','replaced','cancelled')
    and vc.assigned_seats>=vc.normal_min_seats
    and vc.assigned_revenue_cents>=pace_v2.required_consideration_revenue_cents(
      vc.min_revenue_cents,
      vc.min_value_threshold_ratio,
      vc.below_minimum_operation_mode
    );

  update pace_v2.vehicle_considerations vc
  set
    status='discarded_t72',
    t72_discarded_at=coalesce(vc.t72_discarded_at,now()),
    updated_at=now()
  where vc.departure_id=p_departure_id
    and vc.status not in('withdrawn','confirmed','replaced','cancelled')
    and (
      vc.assigned_seats<vc.normal_min_seats
      or vc.assigned_revenue_cents<pace_v2.required_consideration_revenue_cents(
        vc.min_revenue_cents,
        vc.min_value_threshold_ratio,
        vc.below_minimum_operation_mode
      )
    );

  perform pace_v2.refresh_consideration_totals(p_departure_id);

  select count(*) into viable_count
  from pace_v2.vehicle_considerations vc
  where vc.departure_id=p_departure_id
    and vc.status='under_consideration'
    and vc.assigned_seats>=vc.normal_min_seats;

  select count(*) into uncovered_count
  from pace_v2.bookings b
  where b.departure_id=p_departure_id
    and b.status in ('booked','at_risk','confirmed')
    and not exists (
      select 1
      from pace_v2.booking_allocations ba
      join pace_v2.vehicle_considerations vc
        on vc.id=ba.vehicle_consideration_id
       and vc.status='under_consideration'
      where ba.booking_id=b.id
        and ba.status in ('preliminary','confirmed')
        and ba.seats=b.seats
    );

  if viable_count>0 and uncovered_count=0 then
    update pace_v2.departures
    set status='under_consideration',at_risk_reason=null,updated_at=now()
    where id=p_departure_id;

    update pace_v2.bookings
    set status='booked',updated_at=now()
    where departure_id=p_departure_id and status='at_risk';

    update pace_v2.departure_revenue_gap_rescues
    set status='cancelled',resolved_at=now(),
        resolution='No longer required: T-72 whole-party rebalancing retained viable vehicles for every booking.'
    where departure_id=p_departure_id and status='open';

    insert into pace_v2.allocation_decisions(
      departure_id,decision_type,engine_version,
      decision_reason_code,decision_reason_text,
      input_snapshot,candidate_snapshot,commercial_snapshot,
      quality_snapshot,fairness_snapshot
    )
    select
      p_departure_id,'t72_booked_parties',p_engine_version,
      'T72_WHOLE_PARTY_REBALANCE',
      'Whole booking parties were allocated to maximize viable vehicles; every survivor met its minimum seats and agreed revenue threshold.',
      jsonb_build_object(
        'booking_count',booking_count,
        'total_booked_seats',seats_total,
        'total_booked_revenue_cents',revenue_total,
        'planner_mode',plan_mode,
        'moved_party_count',moved_count
      ),
      coalesce(jsonb_agg(jsonb_build_object(
        'consideration_id',vc.id,
        'vehicle_id',vc.vehicle_id,
        'operator_id',vc.operator_id,
        'assigned_seats',vc.assigned_seats,
        'assigned_revenue_cents',vc.assigned_revenue_cents,
        'normal_min_seats',vc.normal_min_seats,
        'required_revenue_cents',pace_v2.required_consideration_revenue_cents(
          vc.min_revenue_cents,
          vc.min_value_threshold_ratio,
          vc.below_minimum_operation_mode
        ),
        'resulting_status',vc.status
      ) order by vc.normal_base_seat_price_cents,vc.id),'[]'::jsonb),
      jsonb_build_object('viable_vehicle_count',viable_count),
      '{}'::jsonb,'{}'::jsonb
    from pace_v2.vehicle_considerations vc
    where vc.departure_id=p_departure_id;

    return query
    select 'viable'::text,viable_count,seats_total,revenue_total,0;
    return;
  end if;

  select
    vc.id as consideration_id,
    vc.vehicle_id,
    vc.operator_id,
    vc.assigned_revenue_cents,
    pace_v2.required_consideration_revenue_cents(
      vc.min_revenue_cents,
      vc.min_value_threshold_ratio,
      vc.below_minimum_operation_mode
    ) as required_revenue_cents,
    greatest(
      pace_v2.required_consideration_revenue_cents(
        vc.min_revenue_cents,
        vc.min_value_threshold_ratio,
        vc.below_minimum_operation_mode
      )-vc.assigned_revenue_cents,
      0
    ) as gap_cents
  into rescue
  from pace_v2.vehicle_considerations vc
  where vc.departure_id=p_departure_id
    and vc.assigned_seats>=vc.normal_min_seats
    and vc.min_value_threshold_ratio is not null
    and vc.below_minimum_operation_mode<>'never'
    and vc.assigned_revenue_cents<pace_v2.required_consideration_revenue_cents(
      vc.min_revenue_cents,
      vc.min_value_threshold_ratio,
      vc.below_minimum_operation_mode
    )
  order by gap_cents,vc.normal_base_seat_price_cents,
           vc.quality_score_snapshot desc,vc.id
  limit 1;

  update pace_v2.departures
  set status='at_risk',
      at_risk_reason='T-72 reallocation could not place every whole party on a viable vehicle.',
      updated_at=now()
  where id=p_departure_id;

  update pace_v2.bookings
  set status='at_risk',updated_at=now()
  where departure_id=p_departure_id and status='booked';

  insert into pace_v2.allocation_decisions(
    departure_id,decision_type,engine_version,
    decision_reason_code,decision_reason_text,
    input_snapshot,candidate_snapshot,commercial_snapshot,
    quality_snapshot,fairness_snapshot
  )
  select
    p_departure_id,'t72_booked_parties',p_engine_version,
    case
      when plan_mode='no_feasible_whole_party_plan'
        then 'T72_NO_FEASIBLE_WHOLE_PARTY_PLAN'
      else 'T72_ALLOCATION_REQUIRES_MANUAL_REVIEW'
    end,
    case
      when plan_mode='no_feasible_whole_party_plan'
        then 'No complete allocation can keep every booking party whole while satisfying vehicle capacity, minimum-seat, revenue and discount-vehicle constraints. Manual review is required.'
      else 'T-72 allocation requires manual review because not every booking is covered by a viable vehicle.'
    end,
    jsonb_build_object(
      'booking_count',booking_count,
      'total_booked_seats',seats_total,
      'total_booked_revenue_cents',revenue_total,
      'planner_mode',plan_mode,
      'uncovered_booking_count',uncovered_count
    ),
    coalesce(jsonb_agg(jsonb_build_object(
      'consideration_id',vc.id,
      'vehicle_id',vc.vehicle_id,
      'operator_id',vc.operator_id,
      'assigned_seats',vc.assigned_seats,
      'assigned_revenue_cents',vc.assigned_revenue_cents,
      'resulting_status',vc.status
    ) order by vc.id),'[]'::jsonb),
    jsonb_build_object('manual_review_required',true),
    '{}'::jsonb,'{}'::jsonb
  from pace_v2.vehicle_considerations vc
  where vc.departure_id=p_departure_id;

  if rescue.consideration_id is not null then
    insert into pace_v2.departure_revenue_gap_rescues(
      departure_id,status,target_consideration_id,target_vehicle_id,target_operator_id,
      current_revenue_cents,required_revenue_cents,gap_cents,
      expires_at,engine_version
    ) values (
      p_departure_id,'open',rescue.consideration_id,rescue.vehicle_id,rescue.operator_id,
      rescue.assigned_revenue_cents,rescue.required_revenue_cents,rescue.gap_cents,
      d.t24_ts,p_engine_version
    )
    on conflict (departure_id,status)
    do update set
      target_consideration_id=excluded.target_consideration_id,
      target_vehicle_id=excluded.target_vehicle_id,
      target_operator_id=excluded.target_operator_id,
      current_revenue_cents=excluded.current_revenue_cents,
      required_revenue_cents=excluded.required_revenue_cents,
      gap_cents=excluded.gap_cents,
      expires_at=excluded.expires_at,
      engine_version=excluded.engine_version;

    return query
    select 'at_risk_rescue'::text,viable_count,seats_total,revenue_total,
           rescue.gap_cents;
    return;
  end if;

  return query
  select 'at_risk_no_rescue'::text,viable_count,seats_total,revenue_total,
         null::integer;
end;
$$;

revoke all on function pace_v2.evaluate_t72_booked_parties(uuid,text)
  from public,anon,authenticated,service_role;
