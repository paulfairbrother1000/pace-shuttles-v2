create table pace_v2.scheduler_missing_slots (
  id uuid primary key default gen_random_uuid(),
  expected_at timestamptz not null unique,
  detected_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by_run_id uuid references pace_v2.scheduler_runs(id),
  impact_summary text not null default 'Journey operations, T-24 and feedback scheduling, and email delivery may have been delayed until the next successful run.'
);

create table pace_v2.scheduler_missing_slot_alerts (
  id uuid primary key default gen_random_uuid(),
  missing_slot_id uuid not null references pace_v2.scheduler_missing_slots(id) on delete cascade,
  recipient_email text not null,
  resolved_at_snapshot timestamptz,
  status text not null default 'queued' check (status in ('queued','processing','sent','failed')),
  attempts integer not null default 0,
  claimed_at timestamptz,
  sent_at timestamptz,
  next_attempt_at timestamptz,
  failure_reason text,
  provider_reference text,
  unique(missing_slot_id,recipient_email)
);

create index scheduler_missing_slot_alerts_claim_idx
on pace_v2.scheduler_missing_slot_alerts(status,next_attempt_at)
where status in ('queued','processing','failed');

alter table pace_v2.scheduler_missing_slots enable row level security;
alter table pace_v2.scheduler_missing_slot_alerts enable row level security;
revoke all on pace_v2.scheduler_missing_slots,pace_v2.scheduler_missing_slot_alerts from public,anon,authenticated;

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
      where success.execution_source='scheduled'
        and success.status='completed'
      order by success.requested_at
    ) run
    where slot.resolved_at is null
      and run.requested_at>slot.expected_at
      and run.finished_at is not null
      and run.id=(
        select first_run.id from pace_v2.scheduler_runs first_run
        where first_run.execution_source='scheduled'
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

create or replace function public.v2_system_claim_missing_slot_alerts(p_limit integer default 25)
returns table(alert_id uuid,recipient_email text,expected_at timestamptz,detected_at timestamptz,resolved_at timestamptz,impact_summary text)
language sql
security definer
set search_path=''
as $function$
  with claimed as (
    update pace_v2.scheduler_missing_slot_alerts alert
    set status='processing',attempts=alert.attempts+1,claimed_at=now(),next_attempt_at=null
    where alert.id in (
      select candidate.id from pace_v2.scheduler_missing_slot_alerts candidate
      where candidate.attempts<12
        and coalesce(candidate.next_attempt_at,'-infinity'::timestamptz)<=now()
        and (candidate.status in('queued','failed')
          or (candidate.status='processing' and candidate.claimed_at<now()-interval '15 minutes'))
      order by candidate.id
      for update skip locked
      limit greatest(1,least(coalesce(p_limit,25),100))
    )
    returning alert.*
  )
  select claimed.id,claimed.recipient_email,slot.expected_at,slot.detected_at,claimed.resolved_at_snapshot,slot.impact_summary
  from claimed join pace_v2.scheduler_missing_slots slot on slot.id=claimed.missing_slot_id
$function$;

create or replace function public.v2_system_mark_missing_slot_alert_sent(p_alert_id uuid,p_provider_reference text default null)
returns void language plpgsql security definer set search_path=''
as $function$
begin
  update pace_v2.scheduler_missing_slot_alerts
  set status='sent',sent_at=now(),failure_reason=null,next_attempt_at=null,provider_reference=p_provider_reference
  where id=p_alert_id and status='processing';
  if not found then raise exception 'active missing-slot alert not found'; end if;
end
$function$;

create or replace function public.v2_system_mark_missing_slot_alert_failed(p_alert_id uuid,p_failure_reason text)
returns void language plpgsql security definer set search_path=''
as $function$
begin
  update pace_v2.scheduler_missing_slot_alerts
  set status='failed',failure_reason=left(p_failure_reason,500),
      next_attempt_at=now()+interval '5 minutes'*least(greatest(attempts,1),12)
  where id=p_alert_id and status='processing';
  if not found then raise exception 'active missing-slot alert not found'; end if;
end
$function$;

create or replace function public.v2_site_admin_missing_scheduler_slots(p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare v_rows jsonb;
begin
  if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
  select coalesce(jsonb_agg(to_jsonb(slot) order by slot.expected_at desc),'[]'::jsonb)
  into v_rows
  from (select * from pace_v2.scheduler_missing_slots order by expected_at desc
        limit greatest(1,least(coalesce(p_limit,100),200))) slot;
  return v_rows;
end
$function$;

revoke all on function public.v2_system_detect_missing_scheduled_slots(timestamptz,integer),
 public.v2_system_claim_missing_slot_alerts(integer),
 public.v2_system_mark_missing_slot_alert_sent(uuid,text),
 public.v2_system_mark_missing_slot_alert_failed(uuid,text),
 public.v2_site_admin_missing_scheduler_slots(integer)
 from public,anon,authenticated;
grant execute on function public.v2_system_detect_missing_scheduled_slots(timestamptz,integer),
 public.v2_system_claim_missing_slot_alerts(integer),
 public.v2_system_mark_missing_slot_alert_sent(uuid,text),
 public.v2_system_mark_missing_slot_alert_failed(uuid,text) to service_role;
grant execute on function public.v2_site_admin_missing_scheduler_slots(integer) to authenticated;
