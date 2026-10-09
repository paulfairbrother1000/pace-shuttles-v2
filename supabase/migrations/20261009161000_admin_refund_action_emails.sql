create table pace_v2.refund_admin_actions(
 refund_request_id uuid primary key references pace_v2.refund_requests(id),
 action text not null check(action in('execute','decline')),
 actor_user_id uuid not null references auth.users(id),
 amount_cents integer not null check(amount_cents>=0),
 currency text not null default 'USD', payment_intent_id text,
 provider_refund_id text, status text not null,
 attempts integer not null default 1, lease_until timestamptz,
 failure_reason text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table pace_v2.refund_admin_actions enable row level security;
revoke all on pace_v2.refund_admin_actions from public,anon,authenticated;

create or replace function pace_v2.queue_refund_admin_action_email(p_refund_request_id uuid)
returns integer language plpgsql security definer set search_path='' as $$
declare rr record; recipient record; base text; body text; amount text; n integer:=0;
begin
 select r.*,b.departure_id,b.customer_name,d.scheduled_departure_ts,d.trip_timezone,route.route_name
 into rr from pace_v2.refund_requests r join pace_v2.bookings b on b.id=r.booking_id
 join pace_v2.departures d on d.id=b.departure_id join pace_v2.routes route on route.id=d.route_id
 where r.id=p_refund_request_id and r.status in('requested','approved','failed');
 if not found then return 0; end if;
 base:='https://www.paceshuttles.com/admin/refunds/'||rr.id::text;
 amount:='$'||to_char(coalesce(rr.approved_refund_cents,rr.requested_refund_cents)/100.0,'FM999999990.00')||' '||rr.currency;
 body:='A customer refund requires Site Admin attention.'||chr(10)||chr(10)
   ||'Customer: '||coalesce(rr.customer_name,'Customer')||chr(10)||'Refund: '||amount||chr(10)
   ||'Reason: '||rr.reason||chr(10)||'Journey: '||rr.route_name||chr(10)
   ||'Departure: '||to_char(rr.scheduled_departure_ts at time zone rr.trip_timezone,'DD Mon YYYY HH24:MI')||' ('||rr.trip_timezone||')'||chr(10)
   ||'Booking: '||rr.booking_id::text||chr(10)||'Refund request: '||rr.id::text||chr(10)||chr(10)
   ||'Approve and execute refund: '||base||'?action=execute'||chr(10)
   ||'Decline refund: '||base||'?action=decline'||chr(10)
   ||'Review all refunds: https://www.paceshuttles.com/admin/finance'||chr(10)||chr(10)
   ||'Sign in as Site Admin. Review the request, then click the action button. Opening this email or its links does not move money.';
 for recipient in select distinct lower(trim(u.email)) email from pace_v2.profiles p
 join auth.users u on u.id=p.user_id where p.platform_role='site_admin' and u.deleted_at is null
 and (u.banned_until is null or u.banned_until<=now()) and pace_v2.is_valid_customer_notification_email(u.email)
 and lower(u.email) !~ '@[^@]+[.](test|invalid|example)$'
 loop
   if not exists(select 1 from pace_v2.notifications where template_code='REFUND_ACTION_REQUIRED_ADMIN'
     and metadata->>'refund_request_id'=rr.id::text and to_email=recipient.email) then
    insert into pace_v2.notifications(booking_id,departure_id,channel,to_email,template_code,subject,body,status,scheduled_at,metadata)
    values(rr.booking_id,rr.departure_id,'email',recipient.email,'REFUND_ACTION_REQUIRED_ADMIN',
      'ACTION REQUIRED: Pace Shuttles refund '||amount,body,'queued',now(),
      jsonb_build_object('refund_request_id',rr.id,'approve_url',base||'?action=execute','decline_url',base||'?action=decline',
        'amount_label',amount,'customer_name',rr.customer_name,'reason',rr.reason,'route_name',rr.route_name))
    on conflict do nothing;
    if found then n:=n+1; end if;
   end if;
 end loop;
 return n;
end $$;
create unique index refund_admin_email_once on pace_v2.notifications((metadata->>'refund_request_id'),to_email)
where template_code='REFUND_ACTION_REQUIRED_ADMIN';
create or replace function pace_v2.refund_admin_action_email_trigger()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status in('requested','approved','failed') then perform pace_v2.queue_refund_admin_action_email(new.id); end if;
 return new;
end $$;
create trigger refund_admin_action_email after insert or update of status on pace_v2.refund_requests
for each row execute function pace_v2.refund_admin_action_email_trigger();

create or replace function public.v2_admin_refund_action_context(p_refund_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if not pace_v2.is_site_admin() then raise exception using errcode='42501',message='Site Admin required'; end if;
 select to_jsonb(r)||jsonb_build_object('customer_name',b.customer_name,'departure_id',b.departure_id,
  'route_name',route.route_name,'scheduled_departure_ts',d.scheduled_departure_ts,'trip_timezone',d.trip_timezone,
  'execution',to_jsonb(a)) into result from pace_v2.refund_requests r
 join pace_v2.bookings b on b.id=r.booking_id join pace_v2.departures d on d.id=b.departure_id
 join pace_v2.routes route on route.id=d.route_id left join pace_v2.refund_admin_actions a on a.refund_request_id=r.id
 where r.id=p_refund_request_id;
 if result is null then raise exception 'Refund request not found'; end if;
 return result;
end $$;

create or replace function public.v2_admin_begin_refund_execution(p_refund_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare rr pace_v2.refund_requests%rowtype; a pace_v2.refund_admin_actions%rowtype; pi text; amount integer;
begin
 if not pace_v2.is_site_admin() then raise exception using errcode='42501',message='Site Admin required'; end if;
 select * into rr from pace_v2.refund_requests where id=p_refund_request_id for update;
 if not found then raise exception 'Refund request not found'; end if;
 if rr.status='paid' then return jsonb_build_object('status','paid'); end if;
 if rr.status not in('requested','approved') then raise exception 'Refund is not awaiting approval or execution'; end if;
 select * into a from pace_v2.refund_admin_actions where refund_request_id=rr.id for update;
 if found then
   if a.action<>'execute' then raise exception 'Refund was declined'; end if;
   if a.lease_until>now() then raise exception 'Refund is already processing. Check its status shortly.'; end if;
   update pace_v2.refund_admin_actions set lease_until=now()+interval '2 minutes',attempts=attempts+1,updated_at=now()
   where refund_request_id=rr.id;
 else
   select stripe_payment_intent_id into pi from pace_v2.payment_transactions
   where order_id=rr.order_id and status='paid' and transaction_type='payment'
   and stripe_payment_intent_id is not null order by completed_at desc nulls last,created_at desc limit 1;
   if pi is null then raise exception 'No Stripe payment is linked. Review the payment in Finance before executing.'; end if;
   amount:=coalesce(rr.approved_refund_cents,rr.requested_refund_cents);
   if amount<=0 then raise exception 'Refund amount must be greater than zero'; end if;
   if rr.status='requested' then perform pace_v2.approve_refund_request(rr.id,amount); end if;
   insert into pace_v2.refund_admin_actions(refund_request_id,action,actor_user_id,amount_cents,currency,payment_intent_id,status,lease_until)
   values(rr.id,'execute',auth.uid(),amount,rr.currency,pi,'processing',now()+interval '2 minutes') returning * into a;
 end if;
 return to_jsonb(a);
end $$;

create or replace function public.v2_admin_decline_refund(p_refund_request_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare rr pace_v2.refund_requests%rowtype;
begin
 if not pace_v2.is_site_admin() then raise exception using errcode='42501',message='Site Admin required'; end if;
 select * into rr from pace_v2.refund_requests where id=p_refund_request_id for update;
 if not found then raise exception 'Refund request not found'; end if;
 if rr.status='rejected' then return; end if;
 if exists(select 1 from pace_v2.refund_admin_actions where refund_request_id=rr.id and action='execute') then
   raise exception 'Refund execution has already started and cannot be declined'; end if;
 if rr.status<>'requested' then raise exception 'Only a requested refund can be declined'; end if;
 perform pace_v2.approve_refund_request(rr.id,0);
 insert into pace_v2.refund_admin_actions(refund_request_id,action,actor_user_id,amount_cents,currency,status)
 values(rr.id,'decline',auth.uid(),0,rr.currency,'declined');
end $$;

create or replace function public.v2_system_finish_admin_refund(p_refund_request_id uuid,p_provider_refund_id text,
 p_status text,p_amount_cents integer,p_currency text,p_payment_intent_id text,p_failure_reason text default null)
returns void language plpgsql security definer set search_path='' as $$
declare a pace_v2.refund_admin_actions%rowtype;
begin
 -- Lock request first, matching approve/decline and the payment-ledger functions.
 perform 1 from pace_v2.refund_requests where id=p_refund_request_id for update;
 select * into a from pace_v2.refund_admin_actions where refund_request_id=p_refund_request_id for update;
 if not found or a.action<>'execute' then raise exception 'No approved execution exists'; end if;
 if p_amount_cents is distinct from a.amount_cents or lower(p_currency) is distinct from lower(a.currency)
   or p_payment_intent_id is distinct from a.payment_intent_id then raise exception 'Stripe refund does not match the approved request'; end if;
 if p_status not in('succeeded','pending','requires_action','failed','canceled','retryable') then raise exception 'Invalid refund result'; end if;
 if p_status<>'retryable' and coalesce(p_provider_refund_id,'') !~ '^re_' then raise exception 'Stripe refund reference required'; end if;
 if a.provider_refund_id is not null and a.provider_refund_id is distinct from p_provider_refund_id then raise exception 'Refund reference cannot change'; end if;
 if a.status='succeeded' then return; end if;
 update pace_v2.refund_admin_actions set provider_refund_id=coalesce(p_provider_refund_id,provider_refund_id),
 status=p_status,lease_until=null,failure_reason=p_failure_reason,updated_at=now() where refund_request_id=a.refund_request_id;
 if p_status='succeeded' then perform pace_v2.record_refund_paid(a.refund_request_id,p_provider_refund_id); end if;
end $$;
revoke all on function pace_v2.queue_refund_admin_action_email(uuid),pace_v2.refund_admin_action_email_trigger(),
 public.v2_admin_refund_action_context(uuid),public.v2_admin_begin_refund_execution(uuid),public.v2_admin_decline_refund(uuid),
 public.v2_system_finish_admin_refund(uuid,text,text,integer,text,text,text) from public,anon,authenticated;
grant execute on function public.v2_admin_refund_action_context(uuid),public.v2_admin_begin_refund_execution(uuid),public.v2_admin_decline_refund(uuid) to authenticated;
grant execute on function public.v2_system_finish_admin_refund(uuid,text,text,integer,text,text,text),pace_v2.queue_refund_admin_action_email(uuid) to service_role;
