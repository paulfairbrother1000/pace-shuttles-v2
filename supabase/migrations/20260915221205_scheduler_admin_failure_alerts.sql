create table pace_v2.scheduler_admin_alert_deliveries(
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references pace_v2.scheduler_runs(id) on delete cascade,
  alert_type text not null check(alert_type in('failure','recovery')),
  recipient_email text not null check(length(trim(recipient_email)) between 3 and 320),
  status text not null default 'queued' check(status in('queued','processing','sent','failed')),
  attempts integer not null default 0 check(attempts>=0),
  claimed_at timestamptz,
  sent_at timestamptz,
  failed_at timestamptz,
  next_attempt_at timestamptz,
  provider_reference text,
  failure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(run_id,alert_type,recipient_email)
);

create index scheduler_admin_alert_delivery_claim_idx
  on pace_v2.scheduler_admin_alert_deliveries(status,next_attempt_at,created_at)
  where status in('queued','processing','failed');

alter table pace_v2.scheduler_admin_alert_deliveries enable row level security;
revoke all on pace_v2.scheduler_admin_alert_deliveries from public,anon,authenticated;

create or replace function pace_v2.queue_scheduler_admin_alerts()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_alert_type text;
begin
  if new.execution_source not in('scheduled','catch_up') then return new; end if;

  if new.status='failed' and old.status is distinct from 'failed' then
    v_alert_type:='failure';
  elsif new.status='failed' and old.resolved_at is null and new.resolved_at is not null then
    v_alert_type:='recovery';
  else
    return new;
  end if;

  insert into pace_v2.scheduler_admin_alert_deliveries(
    run_id,alert_type,recipient_email
  )
  select new.id,v_alert_type,lower(trim(u.email))
  from pace_v2.profiles p
  join auth.users u on u.id=p.user_id
  where p.platform_role='site_admin'
    and u.deleted_at is null
    and (u.banned_until is null or u.banned_until<=now())
    and nullif(trim(u.email),'') is not null
    and lower(trim(u.email)) not like '%@%.test'
    and lower(trim(u.email)) not like '%@%.invalid'
    and lower(trim(u.email)) not like '%@%.example'
  on conflict(run_id,alert_type,recipient_email) do nothing;

  return new;
end
$function$;

drop trigger if exists queue_scheduler_admin_alerts on pace_v2.scheduler_runs;
create trigger queue_scheduler_admin_alerts
after update of status,resolved_at on pace_v2.scheduler_runs
for each row execute function pace_v2.queue_scheduler_admin_alerts();

create or replace function public.v2_system_claim_scheduler_admin_alerts(
  p_limit integer default 25
)
returns table(
  alert_id uuid,
  alert_type text,
  run_id uuid,
  recipient_email text,
  requested_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz,
  failure_phase text,
  failure_reason text,
  impact_summary text,
  resolved_at timestamptz,
  resolution_summary text,
  result jsonb,
  phases jsonb
)
language sql
security definer
set search_path=''
as $function$
  with candidates as (
    select delivery.id
    from pace_v2.scheduler_admin_alert_deliveries delivery
    where delivery.attempts<12
      and coalesce(delivery.next_attempt_at,'-infinity'::timestamptz)<=now()
      and (
        delivery.status in('queued','failed')
        or (delivery.status='processing' and delivery.claimed_at<now()-interval '15 minutes')
      )
    order by delivery.created_at,delivery.id
    for update skip locked
    limit greatest(1,least(coalesce(p_limit,25),100))
  ), claimed as (
    update pace_v2.scheduler_admin_alert_deliveries delivery
    set status='processing',attempts=delivery.attempts+1,claimed_at=now(),
        next_attempt_at=null,failure_reason=null,updated_at=now()
    from candidates
    where delivery.id=candidates.id
    returning delivery.*
  )
  select claimed.id,claimed.alert_type,run.id,claimed.recipient_email,
    run.requested_at,run.started_at,run.finished_at,run.failure_phase,
    run.failure_reason,run.impact_summary,run.resolved_at,run.resolution_summary,
    run.result,
    coalesce((
      select jsonb_agg(to_jsonb(phase) order by phase.started_at)
      from pace_v2.scheduler_run_phases phase where phase.run_id=run.id
    ),'[]'::jsonb)
  from claimed
  join pace_v2.scheduler_runs run on run.id=claimed.run_id
  order by claimed.created_at,claimed.id
$function$;

create or replace function public.v2_system_mark_scheduler_admin_alert_sent(
  p_alert_id uuid,
  p_provider_reference text default null
)
returns void
language plpgsql
security definer
set search_path=''
as $function$
begin
  update pace_v2.scheduler_admin_alert_deliveries
  set status='sent',sent_at=now(),failed_at=null,next_attempt_at=null,
      provider_reference=nullif(trim(coalesce(p_provider_reference,'')),''),
      failure_reason=null,updated_at=now()
  where id=p_alert_id and status='processing';
  if not found then raise exception 'active scheduler alert delivery not found'; end if;
end
$function$;

create or replace function public.v2_system_mark_scheduler_admin_alert_failed(
  p_alert_id uuid,
  p_failure_reason text
)
returns void
language plpgsql
security definer
set search_path=''
as $function$
begin
  update pace_v2.scheduler_admin_alert_deliveries
  set status='failed',failed_at=now(),
      next_attempt_at=now()+interval '5 minutes'*least(greatest(attempts,1),12),
      failure_reason=left(coalesce(nullif(trim(p_failure_reason),''),'Unknown scheduler alert failure'),500),
      updated_at=now()
  where id=p_alert_id and status='processing';
  if not found then raise exception 'active scheduler alert delivery not found'; end if;
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
      'reason',sc.change_reason,
      'next_scheduled_run_at',date_trunc('hour',now())+interval '1 hour'
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

revoke all on function public.v2_system_claim_scheduler_admin_alerts(integer) from public,anon,authenticated;
grant execute on function public.v2_system_claim_scheduler_admin_alerts(integer) to service_role;

revoke all on function public.v2_system_mark_scheduler_admin_alert_sent(uuid,text) from public,anon,authenticated;
grant execute on function public.v2_system_mark_scheduler_admin_alert_sent(uuid,text) to service_role;

revoke all on function public.v2_system_mark_scheduler_admin_alert_failed(uuid,text) from public,anon,authenticated;
grant execute on function public.v2_system_mark_scheduler_admin_alert_failed(uuid,text) to service_role;

revoke all on function public.v2_site_admin_scheduler_dashboard() from public,anon,authenticated;
grant execute on function public.v2_site_admin_scheduler_dashboard() to authenticated;
