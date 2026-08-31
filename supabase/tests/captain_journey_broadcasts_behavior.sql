begin;

-- This fixture only touches the deterministically selected local seed allocation.
-- It requires five allocated bookings with party-leader auth users and uses a
-- rollback so it is safe to execute repeatedly against the local test database.
create temporary table captain_broadcast_fixture(
  allocation_id uuid not null,
  departure_id uuid not null,
  captain_user_id uuid not null,
  operator_user_id uuid not null,
  paid_booking_a_id uuid not null,
  paid_booking_b_id uuid not null,
  paid_booking_c_id uuid not null,
  cancelled_booking_id uuid not null,
  unpaid_booking_id uuid not null,
  owner_a_id uuid not null,
  owner_b_id uuid not null,
  owner_c_id uuid not null,
  request_id uuid not null default gen_random_uuid(),
  source_message_id uuid,
  second_source_message_id uuid,
  paid_delivery_a_id uuid,
  paid_notification_a_id uuid,
  valid_claim_notification_id uuid,
  malformed_notification_before_claim jsonb
) on commit drop;
grant select,update on captain_broadcast_fixture to authenticated;

insert into captain_broadcast_fixture(
  allocation_id,departure_id,captain_user_id,operator_user_id,
  paid_booking_a_id,paid_booking_b_id,paid_booking_c_id,cancelled_booking_id,unpaid_booking_id,
  owner_a_id,owner_b_id,owner_c_id
)
select ca.id,ca.departure_id,c.auth_user_id,operator_user.user_id,
  candidates.booking_ids[1],candidates.booking_ids[2],candidates.booking_ids[3],candidates.booking_ids[4],candidates.booking_ids[5],
  candidates.owner_ids[1],candidates.owner_ids[2],candidates.owner_ids[3]
from pace_v2.confirmed_allocations ca
join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
join pace_v2.captains c on c.id=a.captain_id and c.active and c.operator_id=ca.operator_id and c.auth_user_id is not null
join pace_v2.captain_vehicle_types cvt on cvt.captain_id=c.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
join lateral (
  select array_agg(x.booking_id order by x.booking_id) as booking_ids,array_agg(x.owner_id order by x.booking_id) as owner_ids
  from (
    select distinct on (b.id) b.id as booking_id,pace_v2.booking_owner_user_id(b.id) as owner_id
    from pace_v2.bookings b
    join pace_v2.orders o on o.id=b.order_id
    join pace_v2.booking_allocations ba on ba.booking_id=b.id and ba.vehicle_consideration_id=ca.consideration_id
    join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id) and nullif(trim(u.email),'') is not null
    order by b.id
    limit 5
  ) x
) candidates on cardinality(candidates.booking_ids)=5 and candidates.owner_ids[1]<>candidates.owner_ids[2] and candidates.owner_ids[1]<>candidates.owner_ids[3] and candidates.owner_ids[2]<>candidates.owner_ids[3]
join lateral (
  select om.user_id from pace_v2.operator_memberships om
  where om.active and om.user_id<>c.auth_user_id
    and not exists(select 1 from pace_v2.captains other_c where other_c.auth_user_id=om.user_id)
  order by om.user_id limit 1
) operator_user on true
where ca.status='confirmed'
order by ca.id,c.id
limit 1;

do $$ begin
  if not exists(select 1 from captain_broadcast_fixture) then
    raise exception 'fixture requires one eligible captain allocation with five email-backed party-leader bookings and an operator-only user';
  end if;
end $$;

update pace_v2.departures d
set scheduled_departure_ts=now()+interval '24 hours',scheduled_arrival_ts=now()+interval '26 hours',actual_arrival_ts=null
from captain_broadcast_fixture f where d.id=f.departure_id;
update pace_v2.bookings b set status='booked'
from captain_broadcast_fixture f where b.id in(f.paid_booking_a_id,f.paid_booking_b_id,f.paid_booking_c_id,f.unpaid_booking_id);
update pace_v2.bookings b set status='cancelled'
from captain_broadcast_fixture f where b.id=f.cancelled_booking_id;
update pace_v2.orders o set payment_status='paid'
from pace_v2.bookings b,captain_broadcast_fixture f where o.id=b.order_id and b.id in(f.paid_booking_a_id,f.paid_booking_b_id,f.paid_booking_c_id,f.cancelled_booking_id);
update pace_v2.orders o set payment_status='pending'
from pace_v2.bookings b,captain_broadcast_fixture f where o.id=b.order_id and b.id=f.unpaid_booking_id;
update pace_v2.bookings b set status='cancelled'
from captain_broadcast_fixture f join pace_v2.booking_allocations ba on ba.vehicle_consideration_id=(select ca.consideration_id from pace_v2.confirmed_allocations ca where ca.id=f.allocation_id)
where b.id=ba.booking_id and b.id not in(f.paid_booking_a_id,f.paid_booking_b_id,f.paid_booking_c_id,f.cancelled_booking_id,f.unpaid_booking_id);
update auth.users u set email='malformed-email' from captain_broadcast_fixture f where u.id=f.owner_b_id;
update auth.users u set email=null from captain_broadcast_fixture f where u.id=f.owner_c_id;

select set_config('request.jwt.claim.sub',(select captain_user_id::text from captain_broadcast_fixture),true);
set local role authenticated;
update captain_broadcast_fixture
set source_message_id=public.v2_captain_broadcast_to_parties(allocation_id,'We are running 15 minutes late.','late_running',request_id);
do $$ declare v_repeat uuid; begin
  select public.v2_captain_broadcast_to_parties(allocation_id,'We are running 15 minutes late.','late_running',request_id) into v_repeat from captain_broadcast_fixture;
  if v_repeat is distinct from (select source_message_id from captain_broadcast_fixture) then raise exception 'same broadcast request did not return its original source'; end if;
end $$;
do $$ declare v_second uuid; begin
  select public.v2_captain_broadcast_to_parties(allocation_id,'A separate intentional update.','operational',gen_random_uuid()) into v_second from captain_broadcast_fixture;
  if v_second is not distinct from (select source_message_id from captain_broadcast_fixture) then raise exception 'different broadcast request did not create a distinct source'; end if;
  update captain_broadcast_fixture set second_source_message_id=v_second;
end $$;
reset role;

update captain_broadcast_fixture f
set paid_notification_a_id=(
  select n.id from pace_v2.notifications n
  join pace_v2.journey_broadcast_deliveries d on n.metadata->>'journey_broadcast_delivery_id'=d.id::text
  where d.broadcast_message_id=f.source_message_id and d.booking_id=f.paid_booking_a_id
),valid_claim_notification_id=(
  select n.id from pace_v2.notifications n
  join pace_v2.journey_broadcast_deliveries d on n.metadata->>'journey_broadcast_delivery_id'=d.id::text
  where d.broadcast_message_id=f.second_source_message_id and d.booking_id=f.paid_booking_a_id
);
update pace_v2.notifications n
set to_email='legacy-malformed',status='queued',scheduled_at=now()-interval '10 years'
from captain_broadcast_fixture f where n.id=f.paid_notification_a_id;
update pace_v2.notifications n
set status='queued',scheduled_at=now()-interval '9 years'
from captain_broadcast_fixture f where n.id=f.valid_claim_notification_id;
update captain_broadcast_fixture f set malformed_notification_before_claim=(
  select to_jsonb(n) from pace_v2.notifications n where n.id=f.paid_notification_a_id
);
create temporary table captain_broadcast_claims on commit drop as
select * from public.v2_system_claim_due_customer_emails_with_metadata(1);
do $$ begin
  if exists(
    select 1 from captain_broadcast_fixture f join captain_broadcast_claims c on c.notification_id=f.paid_notification_a_id
  ) then raise exception 'legacy malformed notification appeared in claim results'; end if;
  if exists(
    select 1 from captain_broadcast_fixture f join pace_v2.notifications n on n.id=f.paid_notification_a_id
    where to_jsonb(n) is distinct from f.malformed_notification_before_claim
  ) then raise exception 'legacy malformed notification changed during claim'; end if;
  if (select count(*) from captain_broadcast_fixture f join captain_broadcast_claims c on c.notification_id=f.valid_claim_notification_id)<>1 then
    raise exception 'valid due notification was not claimed exactly once';
  end if;
  if not exists(
    select 1 from captain_broadcast_fixture f join pace_v2.notifications n on n.id=f.valid_claim_notification_id
    where n.status='sending' and n.scheduled_at>now()
  ) then raise exception 'valid due notification was returned without being claimed'; end if;
end $$;

do $$
declare v_deliveries integer; v_messages integer; v_notifications integer;
begin
  select count(*) into v_deliveries from pace_v2.journey_broadcast_deliveries d
  join captain_broadcast_fixture f on d.broadcast_message_id=f.source_message_id;
  select count(*) into v_messages from pace_v2.journey_conversation_messages m
  join captain_broadcast_fixture f on m.id=f.source_message_id or m.broadcast_source_id=f.source_message_id;
  select count(*) into v_notifications from pace_v2.notifications n
  join captain_broadcast_fixture f on n.metadata->>'journey_broadcast_delivery_id' in (
    select d.id::text from pace_v2.journey_broadcast_deliveries d where d.broadcast_message_id=f.source_message_id
  );
  if v_deliveries<>3 or v_messages<>4 or v_notifications<>3 then
    raise exception 'expected three paid active private deliveries/messages/notifications, got %/%/%',v_deliveries,v_messages,v_notifications;
  end if;
  if exists(
    select 1 from pace_v2.journey_broadcast_deliveries d join captain_broadcast_fixture f on d.broadcast_message_id=f.source_message_id
    where d.booking_id in(f.cancelled_booking_id,f.unpaid_booking_id)
  ) then raise exception 'cancelled or unpaid booking received a broadcast'; end if;
  if exists(
    select booking_id from pace_v2.journey_broadcast_deliveries d join captain_broadcast_fixture f on d.broadcast_message_id=f.source_message_id
    group by booking_id having count(*)<>1
  ) then raise exception 'broadcast fan-out was not retry-safe per booking'; end if;
  if not exists(
    select 1 from pace_v2.journey_conversation_messages m join captain_broadcast_fixture f on m.id=f.source_message_id
    where m.sender_type='captain_broadcast' and m.broadcast_source_id is null
  ) then raise exception 'immutable audited source broadcast missing'; end if;
  if exists(select 1 from pace_v2.journey_conversation_messages m join captain_broadcast_fixture f on m.id=f.source_message_id where m.broadcast_source_id is not null)
    or (select count(*) from pace_v2.journey_conversation_messages m join captain_broadcast_fixture f on m.broadcast_source_id=f.source_message_id)<>3 then raise exception 'every party must receive a source-linked private copy'; end if;
end $$;

do $$
declare v_claimed integer;
begin
  if exists(
    select 1 from pace_v2.notifications n join pace_v2.journey_broadcast_deliveries d on n.metadata->>'journey_broadcast_delivery_id'=d.id::text
    join captain_broadcast_fixture f on d.broadcast_message_id=f.source_message_id and d.booking_id in(f.paid_booking_b_id,f.paid_booking_c_id)
    where n.template_code='journey_broadcast' and n.status='queued'
  ) then raise exception 'invalid email notification entered the claimable queue'; end if;
  if (select count(*) from pace_v2.notifications n join pace_v2.journey_broadcast_deliveries d on n.metadata->>'journey_broadcast_delivery_id'=d.id::text
      join captain_broadcast_fixture f on d.broadcast_message_id=f.source_message_id and d.booking_id in(f.paid_booking_b_id,f.paid_booking_c_id)
      where n.template_code='journey_broadcast' and n.status='failed')<>2 then
    raise exception 'invalid email notification did not remain failed and nonclaimable';
  end if;
  if not exists(
    select 1 from pace_v2.journey_broadcast_deliveries d join captain_broadcast_fixture f on d.broadcast_message_id=f.source_message_id and d.booking_id=f.paid_booking_b_id
    where d.email_status='failed' and d.email_failure_reason='Party leader email is invalid'
  ) or not exists(
    select 1 from pace_v2.journey_broadcast_deliveries d join captain_broadcast_fixture f on d.broadcast_message_id=f.source_message_id and d.booking_id=f.paid_booking_c_id
    where d.email_status='failed' and d.email_failure_reason='Party leader email is unavailable'
  ) then raise exception 'invalid email delivery did not record its reason'; end if;
  if (select count(*) from pace_v2.operational_alerts oa join pace_v2.journey_broadcast_deliveries d on oa.details->>'delivery_id'=d.id::text
      join captain_broadcast_fixture f on d.broadcast_message_id=f.source_message_id and d.booking_id in(f.paid_booking_b_id,f.paid_booking_c_id)
      where oa.exception_type='journey_broadcast_invalid_email' and oa.resolved_at is null and oa.details ? 'reason')<>2 then
    raise exception 'invalid email did not create an operational alert';
  end if;
  select count(*) into v_claimed from public.v2_system_claim_due_customer_emails_with_metadata(25) c
  join captain_broadcast_fixture f on c.booking_id in(f.paid_booking_b_id,f.paid_booking_c_id);
  if v_claimed<>0 then raise exception 'invalid email appeared in the email claim result'; end if;
end $$;

select set_config('request.jwt.claim.sub',(select owner_a_id::text from captain_broadcast_fixture),true);
set local role authenticated;
do $$
declare v_visible integer;
begin
  select count(*) into v_visible
  from public.v2_customer_my_journey_messages m
  join captain_broadcast_fixture f on m.id=f.source_message_id or m.broadcast_source_id=f.source_message_id;
  if v_visible<>1 then raise exception 'party leader could see another party broadcast copy: %',v_visible; end if;
end $$;
reset role;

select set_config('request.jwt.claim.sub',(select operator_user_id::text from captain_broadcast_fixture),true);
set local role authenticated;
do $$
declare v_error text;
begin
  begin
    perform public.v2_captain_broadcast_to_parties((select allocation_id from captain_broadcast_fixture),'operator access denied','operational',gen_random_uuid());
  exception when others then v_error:=sqlerrm;
  end;
  if v_error is distinct from 'captain assignment required' then raise exception 'operator-only user could broadcast: %',v_error; end if;
end $$;
reset role;

update captain_broadcast_fixture f
set paid_delivery_a_id=(
  select d.id from pace_v2.journey_broadcast_deliveries d
  where d.broadcast_message_id=f.source_message_id and d.booking_id=f.paid_booking_a_id
);
update captain_broadcast_fixture f set paid_notification_a_id=(select n.id from pace_v2.notifications n where n.metadata->>'journey_broadcast_delivery_id'=f.paid_delivery_a_id::text);
update pace_v2.notifications n set to_email=u.email,status='sending'
from captain_broadcast_fixture f join auth.users u on u.id=f.owner_a_id
where n.id=f.paid_notification_a_id;
select public.v2_system_mark_journey_broadcast_email_failed(
  (select paid_notification_a_id from captain_broadcast_fixture),(select paid_delivery_a_id from captain_broadcast_fixture),'provider unavailable'
);
do $$ begin
  if not exists(select 1 from pace_v2.journey_broadcast_deliveries d join captain_broadcast_fixture f on d.id=f.paid_delivery_a_id where d.email_status='failed' and d.email_failure_reason='provider unavailable') then
    raise exception 'provider failure did not leave a retryable delivery record';
  end if;
  if not exists(select 1 from pace_v2.journey_conversation_messages m join captain_broadcast_fixture f on m.id=f.source_message_id) then
    raise exception 'provider failure removed the in-app source message';
  end if;
end $$;

rollback;
