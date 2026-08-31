create or replace function pace_v2.is_active_paid_journey_booking(
  p_booking_id uuid,
  p_owner_user_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path=pace_v2,public
as $$
  select exists(
    select 1
    from pace_v2.bookings b
    join pace_v2.orders o on o.id=b.order_id
    where b.id=p_booking_id
      and (p_owner_user_id is null or pace_v2.booking_owner_user_id(b.id)=p_owner_user_id)
      and lower(coalesce(to_jsonb(o)->>'payment_status',to_jsonb(o)->>'status','')) in ('paid','succeeded','complete','completed')
      and lower(coalesce(to_jsonb(b)->>'status','active')) not in ('cancelled','canceled','refunded','inactive')
  );
$$;

create or replace function pace_v2.can_access_journey_conversation(
  p_conversation_id uuid,
  p_audience text
)
returns boolean
language plpgsql
stable
security definer
set search_path=pace_v2,public,auth
as $$
declare
  v_user_id uuid:=auth.uid();
  v_allocation_id uuid;
  v_booking_id uuid;
begin
  if v_user_id is null or p_audience not in ('customer','captain','any') then return false; end if;
  if pace_v2.is_site_admin() then return true; end if;
  select jc.booking_id,jc.confirmed_allocation_id into v_booking_id,v_allocation_id
  from pace_v2.journey_conversations jc where jc.id=p_conversation_id;
  if not found then return false; end if;
  if p_audience in ('customer','any') and exists(
    select 1 from pace_v2.bookings b
    where b.id=v_booking_id and pace_v2.booking_owner_user_id(b.id)=v_user_id
  ) then return true; end if;
  return p_audience in ('captain','any') and exists(
    select 1 from pace_v2.confirmed_allocations ca
    join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
    join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
    join pace_v2.captains c on c.id=a.captain_id and c.active and c.operator_id=ca.operator_id and c.auth_user_id=v_user_id
    join pace_v2.captain_vehicle_types cvt on cvt.captain_id=c.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
    where ca.id=v_allocation_id and ca.status='confirmed'
  );
end;
$$;

create or replace function pace_v2.authorized_journey_message_window(
  p_conversation_id uuid,
  p_audience text
)
returns table(
  messaging_opens_at timestamptz,
  messaging_closes_at timestamptz,
  messaging_window_open boolean
)
language plpgsql
stable
security definer
set search_path=pace_v2,public,auth
as $$
begin
  if not pace_v2.can_access_journey_conversation(p_conversation_id,p_audience) then return; end if;
  return query
  select
    pace_v2.journey_message_opens_at(jc.confirmed_allocation_id),
    pace_v2.journey_message_closes_at(jc.confirmed_allocation_id),
    pace_v2.is_journey_message_window_open(jc.confirmed_allocation_id,now())
  from pace_v2.journey_conversations jc
  where jc.id=p_conversation_id;
end;
$$;

create or replace view public.v2_customer_my_journey_conversations
with (security_barrier=true,security_invoker=true)
as
select
  jc.id,
  jc.booking_id,
  jc.confirmed_allocation_id,
  jc.status,
  jc.opened_at,
  jc.closed_at,
  jc.created_at,
  w.messaging_opens_at,
  w.messaging_closes_at,
  w.messaging_window_open
from pace_v2.journey_conversations jc
cross join lateral pace_v2.authorized_journey_message_window(jc.id,'customer') w
where auth.uid() is not null and pace_v2.can_access_journey_conversation(jc.id,'customer');

create or replace view public.v2_customer_my_journey_messages
with (security_barrier=true,security_invoker=true)
as
select
  jm.id,
  jm.conversation_id,
  jm.sender_type,
  jm.category,
  jm.message_text,
  jm.broadcast_source_id,
  jm.created_at
from pace_v2.journey_conversation_messages jm
where auth.uid() is not null and pace_v2.can_access_journey_conversation(jm.conversation_id,'customer');

create or replace view public.v2_captain_my_journey_conversations
with (security_barrier=true,security_invoker=true)
as
select
  jc.id,
  jc.booking_id,
  jc.confirmed_allocation_id,
  jc.status,
  jc.opened_at,
  jc.closed_at,
  jc.created_at,
  w.messaging_opens_at,
  w.messaging_closes_at,
  w.messaging_window_open
from pace_v2.journey_conversations jc
cross join lateral pace_v2.authorized_journey_message_window(jc.id,'captain') w
where auth.uid() is not null and pace_v2.can_access_journey_conversation(jc.id,'captain');

create or replace view public.v2_captain_my_journey_messages
with (security_barrier=true,security_invoker=true)
as
select
  jm.id,
  jm.conversation_id,
  jm.sender_type,
  jm.category,
  jm.message_text,
  jm.broadcast_source_id,
  jm.created_at
from pace_v2.journey_conversation_messages jm
where auth.uid() is not null and pace_v2.can_access_journey_conversation(jm.conversation_id,'captain');

create or replace function public.v2_customer_open_captain_conversation(
  p_booking_id uuid,
  p_message_text text
)
returns uuid
language plpgsql
security definer
set search_path=public,pace_v2,auth
as $$
declare
  v_user_id uuid:=auth.uid();
  v_allocation_id uuid;
  v_captain_id uuid;
  v_conversation_id uuid;
begin
  if v_user_id is null then raise exception 'authentication required'; end if;
  if p_message_text is null or length(trim(p_message_text)) not between 1 and 4000 then
    raise exception 'message text must be between 1 and 4000 characters';
  end if;

  select ca.id,c.id into v_allocation_id,v_captain_id
  from pace_v2.bookings b
  join pace_v2.booking_allocations ba on ba.booking_id=b.id
  join pace_v2.confirmed_allocations ca
    on ca.consideration_id=ba.vehicle_consideration_id and ca.status='confirmed'
  join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
  join pace_v2.captain_assignments a
    on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains c
    on c.id=a.captain_id and c.active and c.operator_id=ca.operator_id
  join pace_v2.captain_vehicle_types cvt
    on cvt.captain_id=c.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
  where b.id=p_booking_id
    and pace_v2.booking_owner_user_id(b.id)=v_user_id
    and pace_v2.is_active_paid_journey_booking(b.id,v_user_id)
  order by ca.id,c.id
  limit 1;

  if v_allocation_id is null or v_captain_id is null then
    raise exception 'booking does not have an eligible assigned captain';
  end if;
  if not pace_v2.is_journey_message_window_open(v_allocation_id,now()) then
    raise exception 'journey messaging window is closed';
  end if;

  insert into pace_v2.journey_conversations(
    booking_id,confirmed_allocation_id,status,opened_at
  ) values(p_booking_id,v_allocation_id,'open',now())
  on conflict(booking_id,confirmed_allocation_id) do update
    set status='open',opened_at=coalesce(pace_v2.journey_conversations.opened_at,excluded.opened_at),closed_at=null
  returning id into v_conversation_id;

  insert into pace_v2.journey_conversation_messages(
    conversation_id,sender_type,sender_user_id,category,message_text
  ) values(v_conversation_id,'customer',v_user_id,'day_of_travel',p_message_text);

  return v_conversation_id;
end;
$$;

create or replace function public.v2_customer_send_captain_message(
  p_conversation_id uuid,
  p_message_text text
)
returns uuid
language plpgsql
security definer
set search_path=public,pace_v2,auth
as $$
declare
  v_user_id uuid:=auth.uid();
  v_booking_id uuid;
  v_allocation_id uuid;
  v_captain_id uuid;
  v_message_id uuid;
begin
  if v_user_id is null then raise exception 'authentication required'; end if;
  if p_message_text is null or length(trim(p_message_text)) not between 1 and 4000 then
    raise exception 'message text must be between 1 and 4000 characters';
  end if;

  select jc.booking_id,ca.id,c.id into v_booking_id,v_allocation_id,v_captain_id
  from pace_v2.journey_conversations jc
  join pace_v2.bookings b on b.id=jc.booking_id
  join pace_v2.confirmed_allocations ca
    on ca.id=jc.confirmed_allocation_id and ca.status='confirmed'
  join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
  join pace_v2.captain_assignments a
    on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains c
    on c.id=a.captain_id and c.active and c.operator_id=ca.operator_id
  join pace_v2.captain_vehicle_types cvt
    on cvt.captain_id=c.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
  where jc.id=p_conversation_id
    and pace_v2.booking_owner_user_id(b.id)=v_user_id
    and pace_v2.is_active_paid_journey_booking(jc.booking_id,v_user_id)
  order by c.id
  limit 1;

  if v_booking_id is null or v_allocation_id is null or v_captain_id is null then
    raise exception 'journey conversation not found';
  end if;
  if not pace_v2.is_journey_message_window_open(v_allocation_id,now()) then
    raise exception 'journey messaging window is closed';
  end if;

  insert into pace_v2.journey_conversation_messages(
    conversation_id,sender_type,sender_user_id,category,message_text
  ) values(p_conversation_id,'customer',v_user_id,'day_of_travel',p_message_text)
  returning id into v_message_id;
  return v_message_id;
end;
$$;

create or replace function public.v2_captain_reply_to_party(
  p_conversation_id uuid,
  p_message_text text,
  p_category text
)
returns uuid
language plpgsql
security definer
set search_path=public,pace_v2,auth
as $$
declare
  v_user_id uuid:=auth.uid();
  v_booking_id uuid;
  v_allocation_id uuid;
  v_captain_id uuid;
  v_message_id uuid;
begin
  if v_user_id is null then raise exception 'authentication required'; end if;
  if p_message_text is null or length(trim(p_message_text)) not between 1 and 4000 then
    raise exception 'message text must be between 1 and 4000 characters';
  end if;
  if p_category not in ('late_running','pickup_change','weather','safety','operational') then
    raise exception 'invalid captain message category';
  end if;

  select jc.booking_id,ca.id,c.id into v_booking_id,v_allocation_id,v_captain_id
  from pace_v2.journey_conversations jc
  join pace_v2.confirmed_allocations ca
    on ca.id=jc.confirmed_allocation_id and ca.status='confirmed'
  join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
  join pace_v2.captain_assignments a
    on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains c
    on c.id=a.captain_id and c.active and c.operator_id=ca.operator_id
    and c.auth_user_id=v_user_id
  join pace_v2.captain_vehicle_types cvt
    on cvt.captain_id=c.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
  where jc.id=p_conversation_id
    and pace_v2.is_active_paid_journey_booking(jc.booking_id,null);

  if v_booking_id is null or v_allocation_id is null or v_captain_id is null then
    raise exception 'journey conversation not assigned to captain';
  end if;
  if not pace_v2.is_journey_message_window_open(v_allocation_id,now()) then
    raise exception 'journey messaging window is closed';
  end if;

  insert into pace_v2.journey_conversation_messages(
    conversation_id,sender_type,sender_user_id,category,message_text
  ) values(p_conversation_id,'captain',v_user_id,p_category,p_message_text)
  returning id into v_message_id;
  return v_message_id;
end;
$$;

create or replace function public.v2_site_admin_reply_journey_conversation(
  p_conversation_id uuid,
  p_message_text text,
  p_category text default 'operational'
)
returns uuid
language plpgsql
security definer
set search_path=public,pace_v2,auth
as $$
declare
  v_user_id uuid:=auth.uid();
  v_booking_id uuid;
  v_allocation_id uuid;
  v_captain_id uuid;
  v_message_id uuid;
begin
  if v_user_id is null then raise exception 'authentication required'; end if;
  if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
  if p_message_text is null or length(trim(p_message_text)) not between 1 and 4000 then
    raise exception 'message text must be between 1 and 4000 characters';
  end if;
  if p_category not in ('day_of_travel','late_running','pickup_change','weather','safety','operational') then
    raise exception 'invalid site admin message category';
  end if;

  select jc.booking_id,ca.id,c.id into v_booking_id,v_allocation_id,v_captain_id
  from pace_v2.journey_conversations jc
  join pace_v2.confirmed_allocations ca
    on ca.id=jc.confirmed_allocation_id and ca.status='confirmed'
  join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
  join pace_v2.captain_assignments a
    on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains c
    on c.id=a.captain_id and c.active and c.operator_id=ca.operator_id
  join pace_v2.captain_vehicle_types cvt
    on cvt.captain_id=c.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
  where jc.id=p_conversation_id
    and pace_v2.is_active_paid_journey_booking(jc.booking_id,null)
  order by c.id
  limit 1;

  if v_booking_id is null or v_allocation_id is null or v_captain_id is null then
    raise exception 'journey conversation not found';
  end if;
  if not pace_v2.is_journey_message_window_open(v_allocation_id,now()) then
    raise exception 'journey messaging window is closed';
  end if;

  insert into pace_v2.journey_conversation_messages(
    conversation_id,sender_type,sender_user_id,category,message_text
  ) values(p_conversation_id,'site_admin',v_user_id,p_category,p_message_text)
  returning id into v_message_id;
  return v_message_id;
end;
$$;

drop policy if exists journey_conversations_private_read on pace_v2.journey_conversations;
create policy journey_conversations_private_read
on pace_v2.journey_conversations
for select to authenticated
using (
  auth.uid() is not null and pace_v2.can_access_journey_conversation(journey_conversations.id,'any')
);

drop policy if exists journey_messages_private_read on pace_v2.journey_conversation_messages;
create policy journey_messages_private_read
on pace_v2.journey_conversation_messages
for select to authenticated
using (
  auth.uid() is not null and pace_v2.can_access_journey_conversation(journey_conversation_messages.conversation_id,'any')
);

revoke all on pace_v2.journey_conversations,pace_v2.journey_conversation_messages from public,anon,authenticated;
grant select (id,booking_id,confirmed_allocation_id,status,opened_at,closed_at,created_at)
  on pace_v2.journey_conversations to authenticated;
grant select (id,conversation_id,sender_type,category,message_text,broadcast_source_id,created_at)
  on pace_v2.journey_conversation_messages to authenticated;
revoke all on function pace_v2.is_active_paid_journey_booking(uuid,uuid),
  pace_v2.can_access_journey_conversation(uuid,text),
  pace_v2.authorized_journey_message_window(uuid,text) from public,anon,authenticated;
grant execute on function pace_v2.can_access_journey_conversation(uuid,text),
  pace_v2.authorized_journey_message_window(uuid,text) to authenticated;

revoke all on table public.v2_customer_my_journey_conversations,
  public.v2_customer_my_journey_messages,
  public.v2_captain_my_journey_conversations,
  public.v2_captain_my_journey_messages from public,anon;
grant select on table public.v2_customer_my_journey_conversations,
  public.v2_customer_my_journey_messages,
  public.v2_captain_my_journey_conversations,
  public.v2_captain_my_journey_messages to authenticated;

revoke all on function public.v2_customer_open_captain_conversation(uuid,text),
  public.v2_customer_send_captain_message(uuid,text),
  public.v2_captain_reply_to_party(uuid,text,text),
  public.v2_site_admin_reply_journey_conversation(uuid,text,text) from public,anon,authenticated;
grant execute on function public.v2_customer_open_captain_conversation(uuid,text),
  public.v2_customer_send_captain_message(uuid,text),
  public.v2_captain_reply_to_party(uuid,text,text),
  public.v2_site_admin_reply_journey_conversation(uuid,text,text) to authenticated;
