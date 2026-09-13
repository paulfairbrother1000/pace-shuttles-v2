create table pace_v2.scheduler_control(
 control_key text primary key check (control_key='journey_operations'),
 enabled boolean not null default true,
 changed_at timestamptz not null default now(),
 changed_by uuid references auth.users(id),
 change_reason text
);

insert into pace_v2.scheduler_control(control_key,enabled,change_reason)
values('journey_operations',true,'Initial scheduler state')
on conflict(control_key) do nothing;

create table pace_v2.scheduler_audit(
 id uuid primary key default gen_random_uuid(),
 control_key text not null check (control_key='journey_operations'),
 old_enabled boolean not null,
 new_enabled boolean not null,
 reason text,
 actor_user_id uuid references auth.users(id),
 changed_at timestamptz not null default now()
);

create table pace_v2.scheduler_runs(
 id uuid primary key default gen_random_uuid(),
 execution_source text not null check(execution_source in('scheduled','manual','catch_up')),
 requested_at timestamptz not null,
 started_at timestamptz not null default now(),
 finished_at timestamptz,
 status text not null check(status in('running','paused','completed','failed')),
 result jsonb not null default '{}'::jsonb,
 failure_reason text,
 requested_by uuid references auth.users(id)
);

alter table pace_v2.scheduler_control enable row level security;
alter table pace_v2.scheduler_audit enable row level security;
alter table pace_v2.scheduler_runs enable row level security;
revoke all on pace_v2.scheduler_control,pace_v2.scheduler_audit,pace_v2.scheduler_runs from public,anon,authenticated;

create or replace function public.v2_system_scheduler_begin(p_execution_source text,p_requested_at timestamptz)
returns table(run_id uuid,enabled boolean)
language plpgsql security definer set search_path=pace_v2,public
as $$
declare v_enabled boolean; v_run_id uuid; v_status text;
begin
 if p_execution_source not in('scheduled','manual','catch_up') then raise exception 'invalid scheduler execution source'; end if;
 select sc.enabled into v_enabled from pace_v2.scheduler_control sc where sc.control_key='journey_operations';
 v_status:=case when v_enabled then 'running' else 'paused' end;
 insert into pace_v2.scheduler_runs(execution_source,requested_at,status,requested_by)
 values(p_execution_source,p_requested_at,v_status,auth.uid()) returning id into v_run_id;
 return query select v_run_id,v_enabled;
end $$;

create or replace function public.v2_system_scheduler_finish(p_run_id uuid,p_result jsonb,p_failure_reason text default null)
returns void language plpgsql security definer set search_path=pace_v2,public
as $$
begin
 update pace_v2.scheduler_runs set finished_at=now(),result=coalesce(p_result,'{}'::jsonb),
  failure_reason=nullif(left(coalesce(p_failure_reason,''),500),''),
  status=case when nullif(trim(coalesce(p_failure_reason,'')),'') is null then 'completed' else 'failed' end
 where id=p_run_id and status='running';
 if not found then raise exception 'active scheduler run not found'; end if;
end $$;

create or replace function public.v2_site_admin_set_scheduler_enabled(p_enabled boolean,p_reason text default null)
returns jsonb language plpgsql security definer set search_path=pace_v2,public
as $$
declare v_old boolean; v_changed_at timestamptz;
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 if not p_enabled and nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'reason is required when pausing the scheduler'; end if;
 select enabled into v_old from pace_v2.scheduler_control where control_key='journey_operations' for update;
 if v_old is distinct from p_enabled then
  update pace_v2.scheduler_control set enabled=p_enabled,changed_at=now(),changed_by=auth.uid(),change_reason=nullif(trim(coalesce(p_reason,'')),'') where control_key='journey_operations' returning changed_at into v_changed_at;
  insert into pace_v2.scheduler_audit(control_key,old_enabled,new_enabled,reason,actor_user_id,changed_at)
  values('journey_operations',v_old,p_enabled,nullif(trim(coalesce(p_reason,'')),''),auth.uid(),v_changed_at);
 else select changed_at into v_changed_at from pace_v2.scheduler_control where control_key='journey_operations';
 end if;
 return jsonb_build_object('enabled',p_enabled,'changed',v_old is distinct from p_enabled,'changed_at',v_changed_at);
end $$;

create or replace function public.v2_site_admin_scheduler_dashboard()
returns jsonb language plpgsql security definer set search_path=pace_v2,public
as $$
declare v_result jsonb;
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 select jsonb_build_object(
  'control',jsonb_build_object('enabled',sc.enabled,'changed_at',sc.changed_at,'changed_by',sc.changed_by,'reason',sc.change_reason),
  'latest_run',(select to_jsonb(sr) from pace_v2.scheduler_runs sr order by sr.started_at desc limit 1),
  'audit',coalesce((select jsonb_agg(to_jsonb(sa) order by sa.changed_at desc) from (select * from pace_v2.scheduler_audit order by changed_at desc limit 50) sa),'[]'::jsonb)
 ) into v_result from pace_v2.scheduler_control sc where sc.control_key='journey_operations';
 return v_result;
end $$;

create or replace function public.v2_site_admin_scheduled_event_calendar(p_from timestamptz,p_to timestamptz)
returns table(event_key text,departure_id uuid,booking_id uuid,route_name text,event_type text,due_at timestamptz,journey_timezone text,execution_source text,executed_at timestamptz,status text,failure_reason text)
language plpgsql security definer set search_path=pace_v2,public
as $$
declare v_enabled boolean;
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 if p_from is null or p_to is null or p_to<=p_from or p_to-p_from>interval '180 days' then raise exception 'calendar range must be between 1 second and 180 days'; end if;
 select sc.enabled into v_enabled from pace_v2.scheduler_control sc where sc.control_key='journey_operations';
 return query
 with candidate as (
  select b.id as booking_id,d.id as departure_id,concat_ws(' to ',pp.name,dst.name) as route_name,c.timezone as journey_timezone,
   't24'::text as event_type,d.scheduled_departure_ts - interval '24 hours' as due_at
  from pace_v2.bookings b join pace_v2.orders o on o.id=b.order_id
  join pace_v2.departures d on d.id=nullif(to_jsonb(b)->>'departure_id','')::uuid
  join pace_v2.routes r on r.id=d.route_id join pace_v2.countries c on c.id=r.country_id
  join pace_v2.pickup_points pp on pp.id=r.pickup_id join pace_v2.destinations dst on dst.id=r.destination_id
  where lower(coalesce(to_jsonb(o)->>'payment_status',to_jsonb(o)->>'status','')) in('paid','succeeded','complete','completed')
  union all
  select b.id,d.id,concat_ws(' to ',pp.name,dst.name),c.timezone,'feedback',
   coalesce(nullif(to_jsonb(d)->>'actual_arrival_ts','')::timestamptz,nullif(to_jsonb(d)->>'completed_at','')::timestamptz)+interval '4 hours'
  from pace_v2.bookings b join pace_v2.orders o on o.id=b.order_id
  join pace_v2.departures d on d.id=nullif(to_jsonb(b)->>'departure_id','')::uuid
  join pace_v2.routes r on r.id=d.route_id join pace_v2.countries c on c.id=r.country_id
  join pace_v2.pickup_points pp on pp.id=r.pickup_id join pace_v2.destinations dst on dst.id=r.destination_id
  where lower(coalesce(to_jsonb(o)->>'payment_status',to_jsonb(o)->>'status','')) in('paid','succeeded','complete','completed')
 ), joined as (
  select x.*,n.status as notification_status,n.scheduled_at,n.created_at,n.metadata,
   nullif(coalesce(to_jsonb(n)->>'sent_at',to_jsonb(n)->>'failed_at',to_jsonb(n)->>'updated_at'), '')::timestamptz as notification_executed_at,
   coalesce(to_jsonb(n)->>'failure_message',to_jsonb(n)->>'last_error') as notification_failure
  from candidate x left join pace_v2.notifications n on n.booking_id=x.booking_id and n.template_code=case when x.event_type='t24' then 'journey_tomorrow' else 'post_journey_feedback' end
  where x.due_at>=p_from and x.due_at<p_to
 )
 select j.event_type||':'||j.booking_id::text,j.departure_id,j.booking_id,j.route_name,j.event_type,j.due_at,j.journey_timezone,
  coalesce(j.metadata->>'execution_source','scheduled'),coalesce(j.notification_executed_at,case when j.notification_status in('sending','sent','failed') then j.created_at end),
  case when j.notification_status='sent' then 'sent' when j.notification_status='sending' then 'processing' when j.notification_status='failed' then 'failed'
   when not v_enabled and j.due_at<=now() then 'overdue' when not v_enabled then 'paused' when j.due_at<=now() then 'overdue' else 'pending' end,
  left(j.notification_failure,500)
 from joined j order by j.due_at,j.event_type,j.booking_id;
end $$;

create or replace function public.v2_site_admin_manual_trigger_scheduled_event(p_event_type text,p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path=pace_v2,public
as $$
declare v_due_at timestamptz; v_departure_id uuid;
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 if p_event_type not in('t24','feedback') then raise exception 'unsupported scheduled event'; end if;
 select d.id,case when p_event_type='t24' then d.scheduled_departure_ts-interval '24 hours' else coalesce(nullif(to_jsonb(d)->>'actual_arrival_ts','')::timestamptz,nullif(to_jsonb(d)->>'completed_at','')::timestamptz)+interval '4 hours' end
 into v_departure_id,v_due_at from pace_v2.bookings b join pace_v2.departures d on d.id=nullif(to_jsonb(b)->>'departure_id','')::uuid where b.id=p_booking_id;
 if v_departure_id is null then raise exception 'booking journey not found'; end if;
 if v_due_at is null or v_due_at>now() then raise exception 'event is not due yet; use the real-time scheduler test'; end if;
 return jsonb_build_object('booking_id',p_booking_id,'departure_id',v_departure_id,'event_type',p_event_type,'due_at',v_due_at,'execution_source','manual');
end $$;

revoke all on function public.v2_system_scheduler_begin(text,timestamptz),public.v2_system_scheduler_finish(uuid,jsonb,text),public.v2_site_admin_set_scheduler_enabled(boolean,text),public.v2_site_admin_scheduler_dashboard(),public.v2_site_admin_scheduled_event_calendar(timestamptz,timestamptz),public.v2_site_admin_manual_trigger_scheduled_event(text,uuid) from public,anon,authenticated;
grant execute on function public.v2_system_scheduler_begin(text,timestamptz),public.v2_system_scheduler_finish(uuid,jsonb,text) to service_role;
grant execute on function public.v2_site_admin_set_scheduler_enabled(boolean,text),public.v2_site_admin_scheduler_dashboard(),public.v2_site_admin_scheduled_event_calendar(timestamptz,timestamptz),public.v2_site_admin_manual_trigger_scheduled_event(text,uuid) to authenticated;
