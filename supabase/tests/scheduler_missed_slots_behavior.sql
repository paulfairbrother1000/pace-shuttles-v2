begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(5);

-- A recorded hour, one missed hour, then a successful catch-up hour.
insert into pace_v2.scheduler_runs(execution_source,requested_at,started_at,finished_at,status)
values
 ('scheduled','2020-01-02T09:00:00Z','2020-01-02T09:00:00Z','2020-01-02T09:00:01Z','completed'),
 ('scheduled','2020-01-02T11:00:00Z','2020-01-02T11:00:00Z','2020-01-02T11:00:01Z','completed');
select public.v2_system_detect_missing_scheduled_slots('2020-01-02T11:15:00Z',2);
select extensions.ok(exists(
 select 1 from pace_v2.scheduler_missing_slots
 where expected_at='2020-01-02T10:00:00Z'
),'missing hourly invocation is recorded');
select extensions.ok(exists(
 select 1 from pace_v2.scheduler_missing_slots
 where expected_at='2020-01-02T10:00:00Z' and resolved_at='2020-01-02T11:00:01Z'
),'next successful run resolves earlier missed invocation');
select extensions.is((public.v2_system_detect_missing_scheduled_slots('2020-01-02T11:15:00Z',2)->>'missing')::integer,0,'repeated watchdog scan is idempotent');
select extensions.ok(not has_function_privilege('authenticated','public.v2_system_detect_missing_scheduled_slots(timestamptz,integer)','execute'),'client cannot mark arbitrary missing hours');

insert into pace_v2.scheduler_missing_slots(id,expected_at)
values('f0000000-0000-0000-0000-000000000901','2019-01-01T09:00:00Z');
insert into pace_v2.scheduler_missing_slot_alerts(id,missing_slot_id,recipient_email)
values('f0000000-0000-0000-0000-000000000902','f0000000-0000-0000-0000-000000000901','test@example.com');
update pace_v2.scheduler_missing_slots set resolved_at=now()
where id='f0000000-0000-0000-0000-000000000901';
create temp table claimed_missing_slot_alerts as
select * from public.v2_system_claim_missing_slot_alerts(100);
select extensions.is((select resolved_at from claimed_missing_slot_alerts where alert_id='f0000000-0000-0000-0000-000000000902'),null::timestamptz,'a retry preserves the original alert recovery snapshot');

do $assert$
begin
 if not exists(select 1 from pace_v2.scheduler_missing_slots where expected_at='2020-01-02T10:00:00Z' and resolved_at='2020-01-02T11:00:01Z')
 or (public.v2_system_detect_missing_scheduled_slots('2020-01-02T11:15:00Z',2)->>'missing')::integer<>0 then
  raise exception 'missed-slot detection regression';
 end if;
 if (select resolved_at from claimed_missing_slot_alerts where alert_id='f0000000-0000-0000-0000-000000000902') is not null then
  raise exception 'missed-slot alert payload changed after recovery';
 end if;
end
$assert$;
select extensions.finish();
rollback;
