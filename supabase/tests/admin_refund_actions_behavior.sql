do $test$
declare rr uuid; admin_id uuid; amount integer; action jsonb; c integer; failed boolean;
begin
 select id,requested_refund_cents into rr,amount from pace_v2.refund_requests where status='requested' order by requested_at desc limit 1;
 select p.user_id into admin_id from pace_v2.profiles p join auth.users u on u.id=p.user_id where p.platform_role='site_admin' and u.deleted_at is null limit 1;
 if rr is null or admin_id is null then raise notice 'No existing fixture available'; return; end if;
 perform set_config('request.jwt.claim.sub',admin_id::text,true);
 begin
   perform public.v2_admin_decline_refund(rr);
   if (select status from pace_v2.refund_requests where id=rr)<>'rejected' then raise exception 'Decline did not resolve request'; end if;
   perform public.v2_admin_decline_refund(rr);
   if (select count(*) from pace_v2.refund_admin_actions where refund_request_id=rr)<>1 then raise exception 'Duplicate decision recorded'; end if;
   raise exception using errcode='ZX001',message='rollback decline fixture';
 exception when sqlstate 'ZX001' then null;
 end;
 begin
   action:=public.v2_admin_begin_refund_execution(rr);
   if (action->>'amount_cents')::integer<>amount or nullif(action->>'payment_intent_id','') is null then raise exception 'Execution amount or payment context incorrect'; end if;
   failed:=false;
   begin perform public.v2_admin_decline_refund(rr); exception when others then failed:=true; end;
   if not failed then raise exception 'In-flight execution was declined'; end if;
   failed:=false;
   begin perform public.v2_admin_begin_refund_execution(rr); exception when others then failed:=true; end;
   if not failed then raise exception 'Concurrent execution was allowed'; end if;
   perform public.v2_system_finish_admin_refund(rr,'re_transactional_fixture','pending',amount,'USD',action->>'payment_intent_id',null);
   if (select status from pace_v2.refund_requests where id=rr)<>'approved' then raise exception 'Pending refund falsely marked paid'; end if;
   if exists(select 1 from pace_v2.refunds where refund_request_id=rr) then raise exception 'Pending refund created payment ledger evidence'; end if;
   action:=public.v2_admin_begin_refund_execution(rr);
   if action->>'provider_refund_id'<>'re_transactional_fixture' then raise exception 'Retry lost provider reference'; end if;
   failed:=false;
   begin perform public.v2_system_finish_admin_refund(rr,'re_transactional_fixture','succeeded',amount+1,'USD',action->>'payment_intent_id',null); exception when others then failed:=true; end;
   if not failed then raise exception 'Mismatched refund amount accepted'; end if;
   perform public.v2_system_finish_admin_refund(rr,'re_transactional_fixture','succeeded',amount,'USD',action->>'payment_intent_id',null);
   perform public.v2_system_finish_admin_refund(rr,'re_transactional_fixture','succeeded',amount,'USD',action->>'payment_intent_id',null);
   if (select count(*) from pace_v2.refunds where refund_request_id=rr)<>1 or (select status from pace_v2.refund_requests where id=rr)<>'paid' then raise exception 'Successful refund was not recorded once'; end if;
   perform pace_v2.queue_refund_admin_action_email(rr);
   set constraints all immediate;
   raise exception using errcode='ZX001',message='rollback execution fixture';
 exception when sqlstate 'ZX001' then null;
 end;
 begin
   c:=pace_v2.queue_refund_admin_action_email(rr);
   perform pace_v2.queue_refund_admin_action_email(rr);
   if not exists(select 1 from pace_v2.notifications where template_code='REFUND_ACTION_REQUIRED_ADMIN' and metadata->>'refund_request_id'=rr::text) then raise exception 'Refund email missing'; end if;
   if exists(select 1 from pace_v2.notifications where template_code='REFUND_ACTION_REQUIRED_ADMIN' and metadata->>'refund_request_id'=rr::text group by to_email having count(*)>1) then raise exception 'Duplicate admin emails'; end if;
   raise exception using errcode='ZX001',message='rollback email fixture';
 exception when sqlstate 'ZX001' then null;
 end;
 perform set_config('request.jwt.claim.sub','',true);
 failed:=false;
 begin perform public.v2_admin_refund_action_context(rr); exception when others then failed:=true; end;
 if not failed then raise exception 'Unauthenticated refund access allowed'; end if;
 raise notice 'PASS: admin access, decline, concurrency, pending/success semantics, duplicate prevention and email actions';
end $test$;
