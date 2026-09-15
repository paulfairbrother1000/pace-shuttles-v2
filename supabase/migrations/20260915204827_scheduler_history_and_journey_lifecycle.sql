alter table pace_v2.departures
  add column if not exists closed_at timestamptz,
  add column if not exists closure_reason text;

alter table pace_v2.scheduler_runs
  add column if not exists current_phase text,
  add column if not exists failure_phase text,
  add column if not exists impact_summary text,
  add column if not exists resolved_at timestamptz,
  add column if not exists resolved_by_run_id uuid references pace_v2.scheduler_runs(id),
  add column if not exists resolution_summary text;

create table pace_v2.scheduler_run_phases(
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references pace_v2.scheduler_runs(id) on delete cascade,
  phase text not null check(phase in(
    'journey_operations','t24_communications','feedback_communications','email_delivery'
  )),
  status text not null check(status in('running','completed','failed')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  result jsonb not null default '{}'::jsonb,
  failure_reason text,
  unique(run_id,phase)
);

create index scheduler_run_phases_run_started_idx
  on pace_v2.scheduler_run_phases(run_id,started_at);

alter table pace_v2.scheduler_run_phases enable row level security;
revoke all on pace_v2.scheduler_run_phases from public,anon,authenticated;

create or replace function pace_v2.guard_service_departure_insert()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_service pace_v2.services%rowtype;
  v_today date;
  v_anchor date;
begin
  if not (
    new.is_commercial
    and new.service_id is not null
    and new.status='scheduled'
    and new.scheduled_departure_ts>now()
  ) then
    return new;
  end if;

  select service.* into v_service
  from pace_v2.services service
  where service.id=new.service_id
  for update;

  if v_service.id is null then
    raise exception 'stale generated departure schedule; retry generation';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('service-return-design:'||v_service.id::text,0)
  );
  perform pg_advisory_xact_lock(hashtextextended(new.id::text,0));

  if not v_service.active
     or not exists(
       select 1
       from pg_catalog.pg_timezone_names timezone_name
       where timezone_name.name=v_service.timezone
     ) then
    raise exception 'stale generated departure schedule; retry generation';
  end if;

  v_today:=(now() at time zone v_service.timezone)::date;
  v_anchor:=coalesce(v_service.recurrence_anchor_date,v_service.valid_from,v_today);

  if not exists(
       select 1 from pace_v2.routes route
       where route.id=v_service.route_id and route.is_active
     )
     or new.route_id is distinct from v_service.route_id
     or new.trip_timezone is distinct from v_service.timezone
     or new.local_departure_date is distinct from
        (new.scheduled_departure_ts at time zone v_service.timezone)::date
     or (new.scheduled_departure_ts at time zone v_service.timezone)::time
        is distinct from v_service.departure_time
     or new.local_departure_date<coalesce(v_service.valid_from,v_today)
     or (v_service.valid_to is not null and new.local_departure_date>v_service.valid_to)
     or coalesce(cardinality(v_service.days_of_week),0)=0
     or extract(isodow from new.local_departure_date)::smallint
        <>all(v_service.days_of_week)
     or (
       coalesce(v_service.recurrence_type,'weekly')='weekly'
       and ((new.local_departure_date-v_anchor)/7)
           % greatest(coalesce(v_service.recurrence_interval_weeks,1),1)<>0
     ) then
    raise exception 'stale generated departure schedule; retry generation';
  end if;

  return new;
end
$function$;

create or replace function public.v2_system_scheduler_phase_start(
  p_run_id uuid,
  p_phase text
)
returns void
language plpgsql
security definer
set search_path=''
as $function$
begin
  if p_phase not in(
    'journey_operations','t24_communications','feedback_communications','email_delivery'
  ) then
    raise exception 'invalid scheduler phase';
  end if;

  update pace_v2.scheduler_runs
  set current_phase=p_phase
  where id=p_run_id and status='running';
  if not found then raise exception 'active scheduler run not found'; end if;

  insert into pace_v2.scheduler_run_phases(run_id,phase,status,started_at)
  values(p_run_id,p_phase,'running',now())
  on conflict(run_id,phase) do update
  set status='running',started_at=now(),finished_at=null,result='{}'::jsonb,
      failure_reason=null;
end
$function$;

create or replace function public.v2_system_scheduler_phase_finish(
  p_run_id uuid,
  p_phase text,
  p_result jsonb,
  p_failure_reason text default null
)
returns void
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_failed boolean:=nullif(trim(coalesce(p_failure_reason,'')),'') is not null;
begin
  update pace_v2.scheduler_run_phases
  set status=case when v_failed then 'failed' else 'completed' end,
      finished_at=now(),
      result=coalesce(p_result,'{}'::jsonb),
      failure_reason=case when v_failed then left(p_failure_reason,500) end
  where run_id=p_run_id and phase=p_phase and status='running';
  if not found then raise exception 'active scheduler phase not found'; end if;

  update pace_v2.scheduler_runs
  set result=coalesce(result,'{}'::jsonb)
      ||jsonb_build_object(p_phase,coalesce(p_result,'{}'::jsonb))
  where id=p_run_id and status='running';
  if not found then raise exception 'active scheduler run not found'; end if;
end
$function$;

create or replace function public.v2_system_scheduler_finish(
  p_run_id uuid,
  p_result jsonb,
  p_failure_reason text default null
)
returns void
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_failed boolean:=nullif(trim(coalesce(p_failure_reason,'')),'') is not null;
  v_phase text;
  v_source text;
  v_finished_at timestamptz:=now();
  v_impact text;
begin
  select current_phase,execution_source into v_phase,v_source
  from pace_v2.scheduler_runs
  where id=p_run_id and status='running'
  for update;
  if not found then raise exception 'active scheduler run not found'; end if;

  v_impact:=case v_phase
    when 'journey_operations' then
      'No journey-generation or T-72/T-24 lifecycle changes committed in this phase. Communication scheduling and email delivery did not run.'
    when 't24_communications' then
      'Journey operations committed, but T-24 communications were not queued in this run. Feedback scheduling and email delivery did not run.'
    when 'feedback_communications' then
      'Journey operations and T-24 scheduling committed, but feedback communications were not queued and email delivery did not run.'
    when 'email_delivery' then
      'Scheduled communications remain queued for retry, but this run did not complete email delivery.'
    else 'The scheduler run did not complete; review its phase evidence before retrying.'
  end;

  update pace_v2.scheduler_runs
  set finished_at=v_finished_at,
      result=coalesce(p_result,result,'{}'::jsonb),
      failure_reason=case when v_failed then left(p_failure_reason,500) end,
      failure_phase=case when v_failed then v_phase end,
      impact_summary=case when v_failed then v_impact end,
      current_phase=null,
      status=case when v_failed then 'failed' else 'completed' end
  where id=p_run_id;

  if not v_failed and v_source in('scheduled','catch_up') then
    update pace_v2.scheduler_runs failed_run
    set resolved_at=v_finished_at,
        resolved_by_run_id=p_run_id,
        resolution_summary='Resolved by successful '||replace(v_source,'_',' ')
          ||' run at '||to_char(v_finished_at at time zone 'UTC','YYYY-MM-DD HH24:MI:SS')||' UTC.'
    where failed_run.status='failed'
      and failed_run.resolved_at is null
      and failed_run.requested_at<v_finished_at
      and failed_run.id<>p_run_id;
  end if;
end
$function$;

create or replace function public.v2_site_admin_scheduler_dashboard()
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_result jsonb;
begin
  if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;

  select jsonb_build_object(
    'control',jsonb_build_object(
      'enabled',sc.enabled,
      'changed_at',sc.changed_at,
      'changed_by',sc.changed_by,
      'reason',sc.change_reason
    ),
    'latest_run',(
      select to_jsonb(sr)||jsonb_build_object(
        'phases',coalesce((
          select jsonb_agg(to_jsonb(srp) order by srp.started_at)
          from pace_v2.scheduler_run_phases srp where srp.run_id=sr.id
        ),'[]'::jsonb)
      )
      from pace_v2.scheduler_runs sr
      order by sr.started_at desc
      limit 1
    ),
    'recent_runs',coalesce((
      select jsonb_agg(recent.run_payload order by recent.started_at desc)
      from (
        select sr.started_at,
          to_jsonb(sr)||jsonb_build_object(
            'phases',coalesce((
              select jsonb_agg(to_jsonb(srp) order by srp.started_at)
              from pace_v2.scheduler_run_phases srp where srp.run_id=sr.id
            ),'[]'::jsonb)
          ) as run_payload
        from pace_v2.scheduler_runs sr
        order by sr.started_at desc
        limit 100
      ) recent
    ),'[]'::jsonb),
    'audit',coalesce((
      select jsonb_agg(to_jsonb(sa) order by sa.changed_at desc)
      from (
        select * from pace_v2.scheduler_audit order by changed_at desc limit 50
      ) sa
    ),'[]'::jsonb)
  ) into v_result
  from pace_v2.scheduler_control sc
  where sc.control_key='journey_operations';

  return v_result;
end
$function$;

create or replace function pace_v2.process_departure_t72(
  p_departure_id uuid,
  p_engine_version text default 'scheduler-v1.3',
  p_force boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path='pace_v2','public'
as $function$
declare
  d pace_v2.departures%rowtype;
  jr uuid;
  booking_count integer;
  result jsonb;
  r record;
begin
  select * into d
  from pace_v2.departures
  where id=p_departure_id
  for update;

  if not found then raise exception 'Departure not found'; end if;
  if not d.is_commercial then return jsonb_build_object('outcome','not_commercial'); end if;
  if not p_force and now()<d.t72_ts then return jsonb_build_object('outcome','not_due'); end if;

  insert into pace_v2.scheduled_job_runs(
    job_name,departure_id,phase,scheduled_for,engine_version
  ) values(
    'departure_window_processor',d.id,'t72',d.t72_ts,p_engine_version
  )
  on conflict do nothing
  returning id into jr;

  if jr is null then return jsonb_build_object('outcome','already_processed'); end if;

  begin
    select coalesce(sum(b.seats),0) into booking_count
    from pace_v2.bookings b
    where b.departure_id=d.id
      and b.status in('booked','at_risk','confirmed');

    if booking_count=0 then
      update pace_v2.vehicle_considerations
      set status='cancelled',updated_at=now()
      where departure_id=d.id
        and status not in('withdrawn','replaced','cancelled');

      update pace_v2.departures
      set status='cancelled',
          cancelled_reason='Cancelled at T-72 — no bookings.',
          at_risk_reason=null
      where id=d.id;

      insert into pace_v2.allocation_decisions(
        departure_id,decision_type,engine_version,
        decision_reason_code,decision_reason_text,
        input_snapshot,candidate_snapshot,commercial_snapshot
      ) values(
        d.id,'t72_zero_booking',p_engine_version,
        'CANCELLED_NO_BOOKINGS_T72','Cancelled at T-72 — no bookings.',
        jsonb_build_object('booked_seats',0),
        coalesce((
          select jsonb_agg(jsonb_build_object(
            'consideration_id',vc.id,'vehicle_id',vc.vehicle_id,
            'operator_id',vc.operator_id,'resulting_status',vc.status
          )) from pace_v2.vehicle_considerations vc where vc.departure_id=d.id
        ),'[]'::jsonb),
        '{}'::jsonb
      );

      result:=jsonb_build_object(
        'outcome','cancelled_no_bookings',
        'reason','Cancelled at T-72 — no bookings.'
      );
    else
      perform pace_v2.refresh_vehicle_considerations(d.id,p_engine_version);

      select to_jsonb(x) into result
      from pace_v2.evaluate_t72_booked_parties(d.id,p_engine_version) x;

      for r in
        select distinct vc.operator_id
        from pace_v2.vehicle_considerations vc
        where vc.departure_id=d.id and vc.status='under_consideration'
      loop
        perform pace_v2.queue_notification(
          r.operator_id,null,d.id,'in_app','T72_UNDER_CONSIDERATION',
          'Journey under consideration',
          'One of your vehicles is under consideration for this journey.',d.t72_ts
        );
      end loop;

      if exists(select 1 from pace_v2.departures x where x.id=d.id and x.status='at_risk') then
        for r in
          select b.id from pace_v2.bookings b
          where b.departure_id=d.id and b.status in('booked','at_risk','confirmed')
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
$function$;

create or replace function public.v2_system_run_scheduled_operations(
  p_t72_limit integer default 50,
  p_t24_limit integer default 50
)
returns jsonb
language plpgsql
security definer
set search_path='public','pace_v2'
as $function$
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
            and b.status in('booked','at_risk','confirmed')
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
$function$;

-- Reconcile already-processed future commercial journeys that had no takers
-- at T-72.  Existing T-72 job rows remain as historical evidence.
insert into pace_v2.allocation_decisions(
  departure_id,decision_type,engine_version,
  decision_reason_code,decision_reason_text,
  input_snapshot,candidate_snapshot,commercial_snapshot
)
select d.id,'t72_zero_booking','scheduler-v1.3-reconciliation',
  'CANCELLED_NO_BOOKINGS_T72','Cancelled at T-72 — no bookings.',
  jsonb_build_object('booked_seats',0,'reconciled',true),
  coalesce((
    select jsonb_agg(jsonb_build_object(
      'consideration_id',vc.id,'vehicle_id',vc.vehicle_id,
      'operator_id',vc.operator_id,'prior_status',vc.status
    )) from pace_v2.vehicle_considerations vc where vc.departure_id=d.id
  ),'[]'::jsonb),
  '{}'::jsonb
from pace_v2.departures d
where d.is_commercial
  and d.t72_ts<=now() and d.scheduled_departure_ts>now()
  and d.status in('scheduled','selling','at_risk','under_consideration')
  and not exists(
    select 1 from pace_v2.bookings b
    where b.departure_id=d.id and b.status in('booked','at_risk','confirmed')
  );

update pace_v2.vehicle_considerations vc
set status='cancelled',updated_at=now()
where vc.departure_id in(
  select d.id from pace_v2.departures d
  where d.is_commercial
    and d.t72_ts<=now() and d.scheduled_departure_ts>now()
    and d.status in('scheduled','selling','at_risk','under_consideration')
    and not exists(
      select 1 from pace_v2.bookings b
      where b.departure_id=d.id and b.status in('booked','at_risk','confirmed')
    )
)
and vc.status not in('withdrawn','replaced','cancelled');

update pace_v2.departures d
set status='cancelled',cancelled_reason='Cancelled at T-72 — no bookings.',
    at_risk_reason=null
where d.is_commercial
  and d.t72_ts<=now() and d.scheduled_departure_ts>now()
  and d.status in('scheduled','selling','at_risk','under_consideration')
  and not exists(
    select 1 from pace_v2.bookings b
    where b.departure_id=d.id and b.status in('booked','at_risk','confirmed')
  );

-- Reconcile past booked journeys whose captain outcome was never recorded.
update pace_v2.departures d
set status='closed_unrecorded'::pace_v2.departure_status,
    closed_at=now(),closure_reason='Closed — travel outcome unrecorded',
    at_risk_reason=null
where d.is_commercial
  and d.status in('confirmed','active')
  and d.actual_arrival_ts is null
  and coalesce(d.scheduled_arrival_ts,d.scheduled_departure_ts+interval '8 hours')
      +interval '24 hours'<=now()
  and exists(
    select 1 from pace_v2.bookings b
    where b.departure_id=d.id and b.status in('booked','at_risk','confirmed')
  );

-- Backfill the incident context that the former dashboard discarded.
update pace_v2.scheduler_runs
set failure_phase='journey_operations',
    impact_summary='No journey-generation or T-72/T-24 lifecycle changes committed in this phase. Communication scheduling and email delivery did not run.'
where status='failed' and failure_phase is null and result='{}'::jsonb;

with resolution as (
  select failed.id as failure_id,(
    select succeeded.id from pace_v2.scheduler_runs succeeded
    where succeeded.status='completed'
      and succeeded.execution_source in('scheduled','catch_up')
      and succeeded.requested_at>failed.requested_at
    order by succeeded.requested_at
    limit 1
  ) as success_id
  from pace_v2.scheduler_runs failed
  where failed.status='failed' and failed.resolved_at is null
), resolved as (
  select r.failure_id,s.id success_id,s.finished_at,s.execution_source
  from resolution r join pace_v2.scheduler_runs s on s.id=r.success_id
)
update pace_v2.scheduler_runs failed
set resolved_at=resolved.finished_at,
    resolved_by_run_id=resolved.success_id,
    resolution_summary='Resolved by successful '
      ||replace(resolved.execution_source,'_',' ')||' run at '
      ||to_char(resolved.finished_at at time zone 'UTC','YYYY-MM-DD HH24:MI:SS')||' UTC.'
from resolved where failed.id=resolved.failure_id;

revoke all on function public.v2_system_scheduler_phase_start(uuid,text),
  public.v2_system_scheduler_phase_finish(uuid,text,jsonb,text)
  from public,anon,authenticated;
grant execute on function public.v2_system_scheduler_phase_start(uuid,text),
  public.v2_system_scheduler_phase_finish(uuid,text,jsonb,text)
  to service_role;

revoke all on function public.v2_system_scheduler_finish(uuid,jsonb,text),
  public.v2_system_run_scheduled_operations(integer,integer)
  from public,anon,authenticated;
grant execute on function public.v2_system_scheduler_finish(uuid,jsonb,text),
  public.v2_system_run_scheduled_operations(integer,integer)
  to service_role;

revoke all on function public.v2_site_admin_scheduler_dashboard()
  from public,anon,authenticated;
grant execute on function public.v2_site_admin_scheduler_dashboard()
  to authenticated;
