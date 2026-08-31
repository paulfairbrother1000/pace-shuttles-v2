create table pace_v2.journey_broadcast_requests(
  request_id uuid primary key,confirmed_allocation_id uuid not null references pace_v2.confirmed_allocations(id),captain_id uuid not null references pace_v2.captains(id),captain_user_id uuid not null references auth.users(id),source_message_id uuid unique references pace_v2.journey_conversation_messages(id),created_at timestamptz not null default now()
);
alter table pace_v2.journey_broadcast_requests enable row level security;
revoke all on pace_v2.journey_broadcast_requests from public,anon,authenticated;
create unique index if not exists customer_notifications_one_journey_broadcast_delivery on pace_v2.notifications((metadata->>'journey_broadcast_delivery_id')) where template_code='journey_broadcast' and metadata ? 'journey_broadcast_delivery_id';

-- The source is an audit record, never a party's private message copy.
drop policy if exists journey_messages_private_read on pace_v2.journey_conversation_messages;
create policy journey_messages_private_read on pace_v2.journey_conversation_messages for select to authenticated using (
 auth.uid() is not null and pace_v2.can_access_journey_conversation(journey_conversation_messages.conversation_id,'any') and not (journey_conversation_messages.sender_type='captain_broadcast' and journey_conversation_messages.broadcast_source_id is null and pace_v2.is_booking_owner((select jc.booking_id from pace_v2.journey_conversations jc where jc.id=journey_conversation_messages.conversation_id)))
);
create or replace view public.v2_customer_my_journey_messages with (security_barrier=true,security_invoker=true) as
select jm.id,jm.conversation_id,jm.sender_type,jm.category,jm.message_text,jm.broadcast_source_id,jm.created_at from pace_v2.journey_conversation_messages jm
where auth.uid() is not null and pace_v2.can_access_journey_conversation(jm.conversation_id,'customer') and not (jm.sender_type='captain_broadcast' and jm.broadcast_source_id is null);

create or replace function pace_v2.is_valid_customer_notification_email(p_email text) returns boolean language sql immutable set search_path=pace_v2,public as $$ select coalesce(nullif(trim(p_email),'') ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$',false); $$;
revoke all on function pace_v2.is_valid_customer_notification_email(text) from public,anon,authenticated;
drop trigger if exists customer_notifications_require_valid_email_before_claim on pace_v2.notifications;
drop function if exists pace_v2.prevent_invalid_customer_email_claim();

create or replace function public.v2_captain_broadcast_to_parties(p_confirmed_allocation_id uuid,p_message_text text,p_category text,p_request_id uuid)
returns uuid language plpgsql security definer set search_path=public,pace_v2,auth as $$
declare
 v_user_id uuid:=auth.uid(); v_captain_id uuid; v_existing pace_v2.journey_broadcast_requests%rowtype; v_created uuid;
 v_source_booking_id uuid; v_source_conversation_id uuid; v_source_message_id uuid; v_conversation_id uuid; v_delivery_id uuid; v_booking record; v_subject text;
begin
 if v_user_id is null then raise exception 'authentication required'; end if;
 if p_request_id is null then raise exception 'broadcast request id required'; end if;
 if pace_v2.is_site_admin() then raise exception 'captain assignment required'; end if;
 if p_message_text is null or length(trim(p_message_text)) not between 1 and 4000 then raise exception 'message text must be between 1 and 4000 characters'; end if;
 if p_category not in ('late_running','pickup_change','weather','safety','operational') then raise exception 'invalid captain broadcast category'; end if;
 select c.id into v_captain_id from pace_v2.confirmed_allocations ca join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active join pace_v2.captains c on c.id=a.captain_id and c.active and c.operator_id=ca.operator_id and c.auth_user_id=v_user_id join pace_v2.captain_vehicle_types cvt on cvt.captain_id=c.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active where ca.id=p_confirmed_allocation_id and ca.status='confirmed' order by c.id limit 1;
 if v_captain_id is null then raise exception 'captain assignment required'; end if;
 if not pace_v2.is_journey_message_window_open(p_confirmed_allocation_id,now()) then raise exception 'journey messaging window is closed'; end if;
 insert into pace_v2.journey_broadcast_requests(request_id,confirmed_allocation_id,captain_id,captain_user_id) values(p_request_id,p_confirmed_allocation_id,v_captain_id,v_user_id) on conflict(request_id) do nothing returning request_id into v_created;
 if v_created is null then
  select * into v_existing from pace_v2.journey_broadcast_requests where request_id=p_request_id for update;
  if v_existing.confirmed_allocation_id<>p_confirmed_allocation_id or v_existing.captain_id<>v_captain_id or v_existing.captain_user_id<>v_user_id then raise exception 'broadcast request belongs to another captain or allocation'; end if;
  if v_existing.source_message_id is null then raise exception 'broadcast request is incomplete'; end if;
  return v_existing.source_message_id;
 end if;
 select b.id into v_source_booking_id from pace_v2.bookings b join pace_v2.booking_allocations ba on ba.booking_id=b.id join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id where ca.id=p_confirmed_allocation_id and pace_v2.booking_owner_user_id(b.id) is not null and pace_v2.is_active_paid_journey_booking(b.id,null) order by b.id limit 1;
 if v_source_booking_id is null then raise exception 'no paid active party bookings'; end if;
 insert into pace_v2.journey_conversations(booking_id,confirmed_allocation_id,status,opened_at,closed_at) values(v_source_booking_id,p_confirmed_allocation_id,'open',now(),null) on conflict(booking_id,confirmed_allocation_id) do update set status='open',opened_at=coalesce(pace_v2.journey_conversations.opened_at,excluded.opened_at),closed_at=null returning id into v_source_conversation_id;
 insert into pace_v2.journey_conversation_messages(conversation_id,sender_type,sender_user_id,category,message_text) values(v_source_conversation_id,'captain_broadcast',v_user_id,p_category,trim(p_message_text)) returning id into v_source_message_id;
 update pace_v2.journey_broadcast_requests set source_message_id=v_source_message_id where request_id=p_request_id;
 for v_booking in select distinct on (b.id) b.id as booking_id,nullif(trim(u.email),'') as to_email,pp.name as pickup_name,dst.name as destination_name,concat_ws(' ',cap.first_name,cap.last_name) as captain_name from pace_v2.bookings b join pace_v2.booking_allocations ba on ba.booking_id=b.id join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.id=p_confirmed_allocation_id join pace_v2.departures d on d.id=ca.departure_id join pace_v2.routes r on r.id=d.route_id join pace_v2.pickup_points pp on pp.id=r.pickup_id join pace_v2.destinations dst on dst.id=r.destination_id join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.id=v_captain_id left join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id) where pace_v2.booking_owner_user_id(b.id) is not null and pace_v2.is_active_paid_journey_booking(b.id,null) order by b.id
 loop
  insert into pace_v2.journey_conversations(booking_id,confirmed_allocation_id,status,opened_at,closed_at) values(v_booking.booking_id,p_confirmed_allocation_id,'open',now(),null) on conflict(booking_id,confirmed_allocation_id) do update set status='open',opened_at=coalesce(pace_v2.journey_conversations.opened_at,excluded.opened_at),closed_at=null returning id into v_conversation_id;
  insert into pace_v2.journey_conversation_messages(conversation_id,sender_type,sender_user_id,category,message_text,broadcast_source_id) values(v_conversation_id,'captain_broadcast',v_user_id,p_category,trim(p_message_text),v_source_message_id);
  insert into pace_v2.journey_broadcast_deliveries(broadcast_message_id,booking_id,conversation_id) values(v_source_message_id,v_booking.booking_id,v_conversation_id) on conflict(broadcast_message_id,booking_id) do nothing returning id into v_delivery_id;
  if v_delivery_id is not null then
   v_subject:='Journey update: '||case p_category when 'late_running' then 'Late running' when 'pickup_change' then 'Pickup update' when 'weather' then 'Weather / conditions' when 'safety' then 'Safety update' when 'operational' then 'Operational update' end;
   insert into pace_v2.notifications(booking_id,departure_id,to_email,template_code,subject,body,status,scheduled_at,metadata) select v_booking.booking_id,ca.departure_id,v_booking.to_email,'journey_broadcast',v_subject,'A new journey update is available in My Journeys. Open the private conversation to view and reply.',case when pace_v2.is_valid_customer_notification_email(v_booking.to_email) then 'queued' else 'failed' end,now(),jsonb_build_object('journey_broadcast_delivery_id',v_delivery_id::text,'pickup_name',v_booking.pickup_name,'destination_name',v_booking.destination_name,'captain_name',v_booking.captain_name,'category',p_category,'message',trim(p_message_text)) from pace_v2.confirmed_allocations ca where ca.id=p_confirmed_allocation_id on conflict do nothing;
   if not pace_v2.is_valid_customer_notification_email(v_booking.to_email) then
    update pace_v2.journey_broadcast_deliveries set email_status='failed',email_failed_at=now(),email_failure_reason=case when v_booking.to_email is null then 'Party leader email is unavailable' else 'Party leader email is invalid' end where id=v_delivery_id;
    insert into pace_v2.operational_alerts(exception_key,exception_type,severity,confirmed_allocation_id,booking_id,departure_id,details) select 'journey_broadcast_invalid_email:'||v_delivery_id::text,'journey_broadcast_invalid_email','medium',p_confirmed_allocation_id,v_booking.booking_id,ca.departure_id,jsonb_build_object('delivery_id',v_delivery_id::text,'request_id',p_request_id::text,'reason',case when v_booking.to_email is null then 'Party leader email is unavailable' else 'Party leader email is invalid' end) from pace_v2.confirmed_allocations ca where ca.id=p_confirmed_allocation_id on conflict (exception_key) where resolved_at is null do update set detected_at=excluded.detected_at,details=excluded.details;
   end if;
  end if;
 end loop;
 return v_source_message_id;
end;
$$;

create or replace function public.v2_system_claim_due_customer_emails_with_metadata(p_limit integer)
returns table(notification_id uuid,to_email text,subject text,body text,template_code text,booking_id uuid,departure_id uuid,metadata jsonb)
language sql security definer set search_path=public,pace_v2 as $$
with claim_candidates as (
 select n.id
 from pace_v2.notifications n
 where n.status in('queued','failed')
   and n.scheduled_at<=now()
   and pace_v2.is_valid_customer_notification_email(n.to_email)
 order by n.scheduled_at,n.id
 limit greatest(coalesce(p_limit,0),0)
 for update of n skip locked
), claimed as (
 update pace_v2.notifications n
 set status='sending',scheduled_at=now()+interval '5 minutes'
 from claim_candidates c
 where n.id=c.id
 returning n.id as notification_id,n.to_email,n.subject,n.body,n.template_code,n.booking_id,n.departure_id,coalesce(n.metadata,'{}'::jsonb) as metadata
)
select c.notification_id,c.to_email,c.subject,c.body,c.template_code,c.booking_id,c.departure_id,c.metadata from claimed c;
$$;
create or replace function public.v2_system_mark_journey_broadcast_email_sent(p_notification_id uuid,p_delivery_id uuid,p_provider_reference text) returns void language plpgsql security definer set search_path=public,pace_v2 as $$ begin if not exists(select 1 from pace_v2.notifications n where n.id=p_notification_id and n.metadata->>'journey_broadcast_delivery_id'=p_delivery_id::text) then raise exception 'broadcast notification and delivery do not match'; end if; perform public.v2_system_mark_email_sent(p_notification_id,p_provider_reference); update pace_v2.journey_broadcast_deliveries set email_status='sent',email_provider_id=nullif(trim(p_provider_reference),''),email_failed_at=null,email_failure_reason=null where id=p_delivery_id; end; $$;
create or replace function public.v2_system_mark_journey_broadcast_email_failed(p_notification_id uuid,p_delivery_id uuid,p_failure_message text) returns void language plpgsql security definer set search_path=public,pace_v2 as $$ begin if not exists(select 1 from pace_v2.notifications n where n.id=p_notification_id and n.metadata->>'journey_broadcast_delivery_id'=p_delivery_id::text) then raise exception 'broadcast notification and delivery do not match'; end if; perform public.v2_system_mark_email_failed(p_notification_id,p_failure_message); update pace_v2.journey_broadcast_deliveries set email_status='failed',email_failed_at=now(),email_failure_reason=left(coalesce(nullif(trim(p_failure_message),''),'Unknown email failure'),1000) where id=p_delivery_id; end; $$;
revoke all on function public.v2_captain_broadcast_to_parties(uuid,text,text,uuid),public.v2_system_claim_due_customer_emails_with_metadata(integer),public.v2_system_mark_journey_broadcast_email_sent(uuid,uuid,text),public.v2_system_mark_journey_broadcast_email_failed(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.v2_captain_broadcast_to_parties(uuid,text,text,uuid) to authenticated;
grant execute on function public.v2_system_claim_due_customer_emails_with_metadata(integer),public.v2_system_mark_journey_broadcast_email_sent(uuid,uuid,text),public.v2_system_mark_journey_broadcast_email_failed(uuid,uuid,text) to service_role;
