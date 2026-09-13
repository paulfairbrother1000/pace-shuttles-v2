begin;
do $$
declare customer_user_id uuid:=gen_random_uuid(); site_admin_user_id uuid:=gen_random_uuid(); v jsonb; v_run record;
begin
 insert into auth.users(id,email) values(customer_user_id,'scheduler-customer@example.test'),(site_admin_user_id,'scheduler-admin@example.test');
 insert into pace_v2.profiles(user_id,email,platform_role) values(customer_user_id,'scheduler-customer@example.test','customer'),(site_admin_user_id,'scheduler-admin@example.test','site_admin');
 set local role authenticated;
 perform set_config('request.jwt.claim.sub',customer_user_id::text,true);
 begin perform public.v2_site_admin_scheduler_dashboard(); raise exception 'customer unexpectedly read scheduler'; exception when others then if sqlerrm not ilike '%site admin required%' then raise; end if; end;
 perform set_config('request.jwt.claim.sub',site_admin_user_id::text,true);
 v:=public.v2_site_admin_set_scheduler_enabled(false,'Testing pause');
 if (v->>'enabled')::boolean then raise exception 'scheduler must be paused'; end if;
 reset role;
 select * into v_run from public.v2_system_scheduler_begin('scheduled',now());
 if v_run.enabled then raise exception 'paused scheduler begin must report disabled'; end if;
 set local role authenticated;
 perform set_config('request.jwt.claim.sub',site_admin_user_id::text,true);
 v:=public.v2_site_admin_set_scheduler_enabled(true,'Resume and catch up');
 if not (v->>'enabled')::boolean then raise exception 'scheduler must be enabled'; end if;
 reset role;
 select * into v_run from public.v2_system_scheduler_begin('catch_up',now());
 if not v_run.enabled then raise exception 'enabled scheduler begin must run'; end if;
 perform public.v2_system_scheduler_finish(v_run.run_id,jsonb_build_object('sent',2),null);
 if not exists(select 1 from pace_v2.scheduler_runs where id=v_run.run_id and status='completed') then raise exception 'scheduler completion missing'; end if;
end $$;
rollback;
