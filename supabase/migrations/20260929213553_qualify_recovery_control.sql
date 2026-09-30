create or replace function public.v2_system_scheduler_recovery_begin(p_execution_source text,p_requested_at timestamptz)
returns table(run_id uuid,enabled boolean)
language plpgsql security definer set search_path to '' as $$
declare v_slot timestamptz:=date_trunc('hour',now());
begin
 if p_execution_source<>'catch_up' then raise exception 'invalid recovery execution source'; end if;
 if abs(extract(epoch from (p_requested_at-now())))>60 then raise exception 'recovery must use the current clock'; end if;
 perform pg_advisory_xact_lock(726029,1);
 if now()<v_slot+interval '10 minutes' then return; end if;
 if not exists(select 1 from pace_v2.scheduler_control sc where sc.control_key='journey_operations' and sc.enabled) then return; end if;
 if exists(select 1 from pace_v2.scheduler_runs where status='running') then return; end if;
 if exists(select 1 from pace_v2.scheduler_runs where requested_at>=v_slot) then return; end if;
 if not exists(select 1 from pace_v2.scheduler_missing_slots where expected_at=v_slot and resolved_at is null) then return; end if;
 return query select * from public.v2_system_scheduler_begin('catch_up',p_requested_at);
end $$;
