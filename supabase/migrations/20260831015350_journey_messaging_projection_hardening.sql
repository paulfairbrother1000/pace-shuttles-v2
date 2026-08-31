-- Convert the previously published customer window view into a no-argument
-- enumeration RPC. The RPC derives every booking from auth.uid(); callers
-- cannot probe a booking id that they do not own.
revoke all on table public.v2_customer_my_journey_message_windows from public,anon,authenticated;
drop view public.v2_customer_my_journey_message_windows;

create or replace function public.v2_customer_my_journey_message_windows()
returns table(booking_id uuid,messaging_opens_at timestamptz,messaging_closes_at timestamptz,messaging_window_open boolean)
language plpgsql stable security definer set search_path=public,pace_v2,auth as $$
begin
 if auth.uid() is null then return; end if;
 return query
 select b.id,w.messaging_opens_at,w.messaging_closes_at,w.messaging_window_open
 from pace_v2.bookings b cross join lateral pace_v2.authorized_customer_booking_message_window(b.id) w
 where pace_v2.booking_owner_user_id(b.id)=auth.uid()
   and pace_v2.is_active_paid_journey_booking(b.id,auth.uid());
end;
$$;
revoke all on function public.v2_customer_my_journey_message_windows() from public,anon,authenticated;
grant execute on function public.v2_customer_my_journey_message_windows() to authenticated;

-- Keep this helper available to its owner for the security-definer RPC above,
-- but remove the obsolete authenticated keyed booking probe.
revoke all on function pace_v2.authorized_customer_booking_message_window(uuid) from public,anon,authenticated;
