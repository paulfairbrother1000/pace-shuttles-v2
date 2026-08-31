create table pace_v2.journey_message_read_states(
  conversation_id uuid not null references pace_v2.journey_conversations(id) on delete cascade,
  reader_user_id uuid not null references auth.users(id) on delete cascade,
  audience text not null check(audience in('customer','captain')),
  last_read_at timestamptz not null default now(),
  primary key(conversation_id,reader_user_id,audience)
);
alter table pace_v2.journey_message_read_states enable row level security;
revoke all on pace_v2.journey_message_read_states from public,anon,authenticated;

create or replace function public.v2_mark_journey_conversation_read(p_conversation_id uuid,p_audience text)
returns void language plpgsql security definer set search_path=public,pace_v2,auth as $$
begin
 if auth.uid() is null then raise exception 'authentication required'; end if;
 if p_audience not in('customer','captain') or pace_v2.is_site_admin() or not pace_v2.can_access_journey_conversation(p_conversation_id,p_audience) then raise exception 'journey conversation not available'; end if;
 insert into pace_v2.journey_message_read_states(conversation_id,reader_user_id,audience,last_read_at)
 values(p_conversation_id,auth.uid(),p_audience,now())
 on conflict(conversation_id,reader_user_id,audience) do update set last_read_at=excluded.last_read_at;
end;
$$;
revoke all on function public.v2_mark_journey_conversation_read(uuid,text) from public,anon,authenticated;
grant execute on function public.v2_mark_journey_conversation_read(uuid,text) to authenticated;

create or replace function pace_v2.authorized_customer_booking_message_window(p_booking_id uuid)
returns table(messaging_opens_at timestamptz,messaging_closes_at timestamptz,messaging_window_open boolean)
language plpgsql stable security definer set search_path=pace_v2,public,auth as $$
declare v_allocation_id uuid;
begin
 if auth.uid() is null then return; end if;
 select ca.id into v_allocation_id
 from pace_v2.bookings b join pace_v2.booking_allocations ba on ba.booking_id=b.id
 join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status='confirmed'
 join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
 join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
 join pace_v2.captains c on c.id=a.captain_id and c.active and c.operator_id=ca.operator_id
 join pace_v2.captain_vehicle_types cvt on cvt.captain_id=c.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
 where b.id=p_booking_id and pace_v2.booking_owner_user_id(b.id)=auth.uid() and pace_v2.is_active_paid_journey_booking(b.id,auth.uid())
 order by ca.id limit 1;
 if v_allocation_id is null then return; end if;
 return query select pace_v2.journey_message_opens_at(v_allocation_id),pace_v2.journey_message_closes_at(v_allocation_id),pace_v2.is_journey_message_window_open(v_allocation_id,now());
end;
$$;
revoke all on function pace_v2.authorized_customer_booking_message_window(uuid) from public,anon,authenticated;
grant execute on function pace_v2.authorized_customer_booking_message_window(uuid) to authenticated;

-- This function is deliberately the only unread projection granted to the UI.
-- The views remain security-invoker while the hidden sender/read-state columns
-- stay inaccessible to ordinary authenticated roles.
create or replace function pace_v2.authorized_journey_conversation_unread_count(p_conversation_id uuid,p_audience text)
returns integer language plpgsql stable security definer set search_path=pace_v2,public,auth as $$
declare v_last_read timestamptz;
begin
 if auth.uid() is null or p_audience not in('customer','captain') or not pace_v2.can_access_journey_conversation(p_conversation_id,p_audience) then return 0; end if;
 select last_read_at into v_last_read from pace_v2.journey_message_read_states where conversation_id=p_conversation_id and reader_user_id=auth.uid() and audience=p_audience;
 return (select count(*)::integer from pace_v2.journey_conversation_messages where conversation_id=p_conversation_id and created_at>coalesce(v_last_read,'epoch'::timestamptz) and sender_user_id is distinct from auth.uid());
end;
$$;
revoke all on function pace_v2.authorized_journey_conversation_unread_count(uuid,text) from public,anon,authenticated;
grant execute on function pace_v2.authorized_journey_conversation_unread_count(uuid,text) to authenticated;

create or replace function pace_v2.authorized_captain_allocation_message_window(p_confirmed_allocation_id uuid)
returns table(messaging_opens_at timestamptz,messaging_closes_at timestamptz,messaging_window_open boolean)
language plpgsql stable security definer set search_path=pace_v2,public,auth as $$
begin
 if auth.uid() is null or pace_v2.is_site_admin() then return; end if;
 if not exists(
  select 1 from pace_v2.confirmed_allocations ca
  join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
  join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains c on c.id=a.captain_id and c.active and c.operator_id=ca.operator_id and c.auth_user_id=auth.uid()
  join pace_v2.captain_vehicle_types cvt on cvt.captain_id=c.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
  where ca.id=p_confirmed_allocation_id and ca.status='confirmed'
 ) then return; end if;
 return query select pace_v2.journey_message_opens_at(p_confirmed_allocation_id),pace_v2.journey_message_closes_at(p_confirmed_allocation_id),pace_v2.is_journey_message_window_open(p_confirmed_allocation_id,now());
end;
$$;
revoke all on function pace_v2.authorized_captain_allocation_message_window(uuid) from public,anon,authenticated;
grant execute on function pace_v2.authorized_captain_allocation_message_window(uuid) to authenticated;

create or replace view public.v2_customer_my_journey_message_windows with (security_barrier=true,security_invoker=true) as
select b.id as booking_id,w.messaging_opens_at,w.messaging_closes_at,w.messaging_window_open
from pace_v2.bookings b cross join lateral pace_v2.authorized_customer_booking_message_window(b.id) w
where auth.uid() is not null and pace_v2.booking_owner_user_id(b.id)=auth.uid();
revoke all on public.v2_customer_my_journey_message_windows from public,anon;
grant select on public.v2_customer_my_journey_message_windows to authenticated;

create or replace view public.v2_captain_my_journey_message_windows with (security_barrier=true,security_invoker=true) as
select j.confirmed_allocation_id,w.messaging_opens_at,w.messaging_closes_at,w.messaging_window_open
from public.v2_captain_my_journeys j cross join lateral pace_v2.authorized_captain_allocation_message_window(j.confirmed_allocation_id) w
where auth.uid() is not null;
revoke all on public.v2_captain_my_journey_message_windows from public,anon;
grant select on public.v2_captain_my_journey_message_windows to authenticated;

create or replace view public.v2_customer_my_journey_conversations with (security_barrier=true,security_invoker=true) as
select jc.id,jc.booking_id,jc.confirmed_allocation_id,jc.status,jc.opened_at,jc.closed_at,jc.created_at,w.messaging_opens_at,w.messaging_closes_at,w.messaging_window_open,
pace_v2.authorized_journey_conversation_unread_count(jc.id,'customer') as unread_count
from pace_v2.journey_conversations jc cross join lateral pace_v2.authorized_journey_message_window(jc.id,'customer') w
where auth.uid() is not null and pace_v2.can_access_journey_conversation(jc.id,'customer');

create or replace view public.v2_captain_my_journey_conversations with (security_barrier=true,security_invoker=true) as
select jc.id,jc.booking_id,jc.confirmed_allocation_id,jc.status,jc.opened_at,jc.closed_at,jc.created_at,w.messaging_opens_at,w.messaging_closes_at,w.messaging_window_open,
pace_v2.authorized_journey_conversation_unread_count(jc.id,'captain') as unread_count
from pace_v2.journey_conversations jc cross join lateral pace_v2.authorized_journey_message_window(jc.id,'captain') w
where auth.uid() is not null and pace_v2.can_access_journey_conversation(jc.id,'captain');
