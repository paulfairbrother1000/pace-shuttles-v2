begin;
-- All synthetic changes and admission records are rolled back; no operations or emails run.
do $$
declare v_run uuid; v_count integer; v_slot timestamptz:=date_trunc('hour',now());
begin
 if now()<v_slot+interval '10 minutes' then raise exception 'Run this test after minute ten'; end if;
 if exists(select 1 from pace_v2.scheduler_runs where status='running') then raise exception 'Do not test during an active run'; end if;
 update pace_v2.scheduler_control set enabled=true where control_key='journey_operations';
 update pace_v2.scheduler_runs set requested_at=requested_at-interval '2 hours' where requested_at>=v_slot;
 insert into pace_v2.scheduler_missing_slots(expected_at) values(v_slot) on conflict(expected_at) do update set resolved_at=null,resolved_by_run_id=null;
 select run_id into v_run from public.v2_system_scheduler_recovery_begin('catch_up',now());
 if v_run is null then raise exception 'Missing slot was not admitted'; end if;
 select count(*) into v_count from public.v2_system_scheduler_recovery_begin('catch_up',now());
 if v_count<>0 then raise exception 'Duplicate recovery admitted'; end if;
 select count(*) into v_count from public.v2_system_scheduler_begin('scheduled',now());
 if v_count<>0 then raise exception 'Overlapping scheduled run admitted'; end if;
 perform public.v2_system_scheduler_finish(v_run,'{}'::jsonb,null);
 perform public.v2_system_detect_missing_scheduled_slots(now(),1);
 if not exists(select 1 from pace_v2.scheduler_missing_slots where expected_at=v_slot and resolved_by_run_id=v_run and resolved_at is not null) then raise exception 'Recovery did not resolve slot'; end if;
 select count(*) into v_count from public.v2_system_scheduler_recovery_begin('catch_up',now());
 if v_count<>0 then raise exception 'Recovered slot admitted twice'; end if;
 if has_function_privilege('anon','public.v2_system_scheduler_recovery_begin(text,timestamptz)','execute') or has_function_privilege('authenticated','public.v2_system_scheduler_recovery_begin(text,timestamptz)','execute') then raise exception 'Recovery endpoint exposed'; end if;
end $$;
rollback;
