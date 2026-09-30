-- Serialize admission across scheduled, manual, and recovery callers.
create or replace function public.v2_system_scheduler_begin(p_execution_source text,p_requested_at timestamptz)
returns table(run_id uuid,enabled boolean)
language plpgsql security definer set search_path to '' as $$
declare v_enabled boolean; v_run_id uuid;
begin
 if p_execution_source not in ('scheduled','manual','catch_up') then raise exception 'invalid scheduler execution source'; end if;
 perform pg_advisory_xact_lock(726029,1);
 if exists(select 1 from pace_v2.scheduler_runs where status='running') then return; end if;
 select sc.enabled into v_enabled from pace_v2.scheduler_control sc where sc.control_key='journey_operations';
 insert into pace_v2.scheduler_runs(execution_source,requested_at,status,requested_by)
 values(p_execution_source,p_requested_at,case when v_enabled then 'running' else 'paused' end,auth.uid()) returning id into v_run_id;
 return query select v_run_id,v_enabled;
end $$;

-- One recovery attempt for the current genuinely missed hourly slot.
create or replace function public.v2_system_scheduler_recovery_begin(p_execution_source text,p_requested_at timestamptz)
returns table(run_id uuid,enabled boolean)
language plpgsql security definer set search_path to '' as $$
declare v_slot timestamptz:=date_trunc('hour',now());
begin
 if p_execution_source<>'catch_up' then raise exception 'invalid recovery execution source'; end if;
 if abs(extract(epoch from (p_requested_at-now())))>60 then raise exception 'recovery must use the current clock'; end if;
 perform pg_advisory_xact_lock(726029,1);
 if now()<v_slot+interval '10 minutes' then return; end if;
 if not exists(select 1 from pace_v2.scheduler_control where control_key='journey_operations' and enabled) then return; end if;
 if exists(select 1 from pace_v2.scheduler_runs where status='running') then return; end if;
 if exists(select 1 from pace_v2.scheduler_runs where requested_at>=v_slot) then return; end if;
 if not exists(select 1 from pace_v2.scheduler_missing_slots where expected_at=v_slot and resolved_at is null) then return; end if;
 return query select * from public.v2_system_scheduler_begin('catch_up',p_requested_at);
end $$;
revoke all on function public.v2_system_scheduler_recovery_begin(text,timestamptz) from public,anon,authenticated;
grant execute on function public.v2_system_scheduler_recovery_begin(text,timestamptz) to service_role;

create or replace function public.v2_system_detect_missing_scheduled_slots(
  p_as_of timestamptz default now(),
  p_hours integer default 168
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_missing integer:=0;
  v_resolved integer:=0;
  v_alerts integer:=0;
begin
  if p_as_of>now()+interval '1 minute' then
    raise exception 'Watchdog observation cannot be in the future';
  end if;
  with hours as (
    select slot as expected_at
    from generate_series(
      date_trunc('hour',p_as_of)-make_interval(hours=>greatest(1,least(coalesce(p_hours,168),168))-1),
      date_trunc('hour',p_as_of),interval '1 hour'
    ) slot
  ), missing as (
    select h.expected_at from hours h
    where h.expected_at+interval '10 minutes'<=p_as_of
      -- Only alert about gaps after the first genuine recorded invocation.
      and exists (
        select 1 from pace_v2.scheduler_runs prior
        where prior.execution_source='scheduled'
          and prior.requested_at<h.expected_at
      )
      and not exists (
        select 1 from pace_v2.scheduler_runs run
        where run.execution_source='scheduled'
          and run.requested_at>=h.expected_at
          and run.requested_at<h.expected_at+interval '1 hour'
      )
  ), inserted as (
    insert into pace_v2.scheduler_missing_slots(expected_at)
    select expected_at from missing
    on conflict(expected_at) do nothing
    returning id
  )
  select count(*) into v_missing from inserted;

  with updated as (
    update pace_v2.scheduler_missing_slots slot
    set resolved_at=run.finished_at,
        resolved_by_run_id=run.id
    from lateral (
      select success.id,success.finished_at,success.requested_at
      from pace_v2.scheduler_runs success
      where success.execution_source in ('scheduled','catch_up')
        and success.status='completed'
      order by success.requested_at
    ) run
    where slot.resolved_at is null
      and run.requested_at>slot.expected_at
      and run.finished_at is not null
      and run.id=(
        select first_run.id from pace_v2.scheduler_runs first_run
        where first_run.execution_source in ('scheduled','catch_up')
          and first_run.status='completed'
          and first_run.requested_at>slot.expected_at
        order by first_run.requested_at limit 1
      )
    returning slot.id
  ) select count(*) into v_resolved from updated;

  with inserted as (
    insert into pace_v2.scheduler_missing_slot_alerts(missing_slot_id,recipient_email,resolved_at_snapshot)
    select slot.id,lower(trim(u.email)),slot.resolved_at
    from pace_v2.scheduler_missing_slots slot
    join pace_v2.profiles p on p.platform_role='site_admin'
    join auth.users u on u.id=p.user_id
    where slot.detected_at>=p_as_of-interval '1 minute'
      and u.deleted_at is null
      and (u.banned_until is null or u.banned_until<=now())
      and nullif(trim(u.email),'') is not null
      and lower(trim(u.email)) not like '%@%.test'
      and lower(trim(u.email)) not like '%@%.invalid'
      and lower(trim(u.email)) not like '%@%.example'
    on conflict(missing_slot_id,recipient_email) do nothing
    returning id
  ) select count(*) into v_alerts from inserted;

  return jsonb_build_object('missing',v_missing,'resolved',v_resolved,'alerts_queued',v_alerts);
end
$function$;

