create table pace_v2.journey_conversations(
 id uuid primary key default gen_random_uuid(),booking_id uuid not null references pace_v2.bookings(id),
 confirmed_allocation_id uuid not null references pace_v2.confirmed_allocations(id),
 status text not null default 'scheduled' check(status in('scheduled','open','closed')),opened_at timestamptz,closed_at timestamptz,
 created_at timestamptz not null default now(),constraint journey_conversations_booking_allocation_key unique(booking_id,confirmed_allocation_id)
);
create table pace_v2.journey_conversation_messages(
 id uuid primary key default gen_random_uuid(),conversation_id uuid not null references pace_v2.journey_conversations(id),
 sender_type text not null check(sender_type in('customer','captain','site_admin','captain_broadcast')),
 sender_user_id uuid references auth.users(id),category text not null check(category in('day_of_travel','late_running','pickup_change','weather','safety','operational')),
 message_text text not null check(length(trim(message_text)) between 1 and 4000),broadcast_source_id uuid references pace_v2.journey_conversation_messages(id),created_at timestamptz not null default now()
);

alter table pace_v2.departures add column if not exists actual_arrival_ts timestamptz;
update pace_v2.departures d
set actual_arrival_ts=vl.actual_arrival_ts
from pace_v2.confirmed_allocations ca
join pace_v2.voyage_logs vl on vl.confirmed_allocation_id=ca.id
where ca.departure_id=d.id
  and vl.actual_arrival_ts is not null
  and d.actual_arrival_ts is distinct from vl.actual_arrival_ts;

create or replace function pace_v2.sync_departure_actual_arrival()
returns trigger language plpgsql set search_path=pace_v2,public as $$
begin
  if new.actual_arrival_ts is not null then
    update pace_v2.departures d set actual_arrival_ts=new.actual_arrival_ts
    from pace_v2.confirmed_allocations ca
    where ca.id=new.confirmed_allocation_id and d.id=ca.departure_id;
  end if;
  return new;
end;
$$;
drop trigger if exists voyage_logs_sync_departure_actual_arrival on pace_v2.voyage_logs;
create trigger voyage_logs_sync_departure_actual_arrival
after insert or update of actual_arrival_ts on pace_v2.voyage_logs
for each row execute function pace_v2.sync_departure_actual_arrival();

create or replace function pace_v2.booking_owner_user_id(p_booking_id uuid)
returns uuid language sql stable security definer set search_path=pace_v2,public as $$
  select o.customer_user_id from pace_v2.bookings b
  join pace_v2.orders o on o.id=b.order_id where b.id=p_booking_id;
$$;
revoke all on function pace_v2.booking_owner_user_id(uuid) from public,anon,authenticated;

create or replace function pace_v2.is_booking_owner(p_booking_id uuid)
returns boolean language sql stable security definer set search_path=pace_v2,public,auth as $$
  select auth.uid() is not null and pace_v2.booking_owner_user_id(p_booking_id)=auth.uid();
$$;
revoke all on function pace_v2.is_booking_owner(uuid) from public,anon;
grant execute on function pace_v2.is_booking_owner(uuid) to authenticated;
create table pace_v2.journey_broadcast_deliveries(
 id uuid primary key default gen_random_uuid(),broadcast_message_id uuid not null references pace_v2.journey_conversation_messages(id),
 booking_id uuid not null references pace_v2.bookings(id),conversation_id uuid not null references pace_v2.journey_conversations(id),
 delivered_at timestamptz not null default now(),in_app_read_at timestamptz,email_status text not null default 'queued' check(email_status in('queued','sent','failed','not_requested')),
 email_provider_id text,email_failed_at timestamptz,email_failure_reason text,created_at timestamptz not null default now(),
 constraint journey_broadcast_deliveries_broadcast_booking_key unique(broadcast_message_id,booking_id)
);
create table pace_v2.operational_alerts(
 id uuid primary key default gen_random_uuid(),exception_key text not null check(length(trim(exception_key)) between 1 and 200),
 exception_type text not null check(length(trim(exception_type)) between 1 and 100),severity text not null default 'high' check(severity in('low','medium','high','critical')),
 confirmed_allocation_id uuid references pace_v2.confirmed_allocations(id),booking_id uuid references pace_v2.bookings(id),departure_id uuid references pace_v2.departures(id),
 details jsonb not null default '{}'::jsonb,detected_at timestamptz not null default now(),resolved_at timestamptz,resolved_by uuid references auth.users(id),resolution_note text,created_at timestamptz not null default now(),check(resolved_at is null or resolved_at>=detected_at)
);
create unique index operational_alerts_active_exception_key on pace_v2.operational_alerts(exception_key) where resolved_at is null;
create index journey_conversations_allocation_idx on pace_v2.journey_conversations(confirmed_allocation_id);
create index journey_messages_conversation_created_idx on pace_v2.journey_conversation_messages(conversation_id,created_at);
create index journey_broadcast_deliveries_conversation_idx on pace_v2.journey_broadcast_deliveries(conversation_id);
create index operational_alerts_open_departure_idx on pace_v2.operational_alerts(departure_id,detected_at) where resolved_at is null;

alter table pace_v2.journey_conversations enable row level security;
alter table pace_v2.journey_conversation_messages enable row level security;
alter table pace_v2.journey_broadcast_deliveries enable row level security;
alter table pace_v2.operational_alerts enable row level security;
revoke all on pace_v2.journey_conversations,pace_v2.journey_conversation_messages,pace_v2.journey_broadcast_deliveries,pace_v2.operational_alerts from public,anon,authenticated;

create or replace function pace_v2.prevent_journey_message_mutation() returns trigger language plpgsql set search_path=pace_v2,public as $$ begin raise exception 'journey messages are immutable'; end; $$;
create trigger journey_messages_are_immutable before update or delete on pace_v2.journey_conversation_messages for each row execute function pace_v2.prevent_journey_message_mutation();

do $$ begin
 if not exists(select 1 from information_schema.columns where table_schema='pace_v2' and table_name='departures' and column_name='actual_arrival_ts' and data_type='timestamp with time zone') then
  raise exception 'pace_v2.departures.actual_arrival_ts required for journey completion window';
 end if;
end $$;

create or replace function pace_v2.journey_message_opens_at(p_confirmed_allocation_id uuid) returns timestamptz language sql stable set search_path=pace_v2,public as $$
 select d.scheduled_departure_ts-interval '24 hours' from pace_v2.confirmed_allocations ca join pace_v2.departures d on d.id=ca.departure_id where ca.id=p_confirmed_allocation_id;
$$;
create or replace function pace_v2.journey_message_closes_at(p_confirmed_allocation_id uuid) returns timestamptz language sql stable set search_path=pace_v2,public as $$
 select coalesce(d.actual_arrival_ts+interval '4 hours',d.scheduled_arrival_ts+interval '12 hours') from pace_v2.confirmed_allocations ca join pace_v2.departures d on d.id=ca.departure_id where ca.id=p_confirmed_allocation_id;
$$;
create or replace function pace_v2.is_journey_message_window_open(p_confirmed_allocation_id uuid,p_as_of timestamptz) returns boolean language sql stable set search_path=pace_v2,public as $$
 select coalesce(p_as_of>=pace_v2.journey_message_opens_at(p_confirmed_allocation_id) and p_as_of<pace_v2.journey_message_closes_at(p_confirmed_allocation_id),false);
$$;
revoke all on function pace_v2.journey_message_opens_at(uuid),pace_v2.journey_message_closes_at(uuid),pace_v2.is_journey_message_window_open(uuid,timestamptz) from public,anon,authenticated;

create or replace function pace_v2.validate_journey_conversation_identity() returns trigger language plpgsql set search_path=pace_v2,public as $$
begin
 if tg_op='UPDATE' and (old.booking_id is distinct from new.booking_id or old.confirmed_allocation_id is distinct from new.confirmed_allocation_id) then raise exception 'journey conversation identity is immutable'; end if;
 if not exists(select 1 from pace_v2.booking_allocations ba join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id where ba.booking_id=new.booking_id and ca.id=new.confirmed_allocation_id) then raise exception 'booking is not allocated to the confirmed allocation'; end if;
 return new;
end; $$;
create trigger journey_conversation_identity_is_immutable before insert or update on pace_v2.journey_conversations for each row execute function pace_v2.validate_journey_conversation_identity();

create or replace function pace_v2.validate_journey_broadcast_delivery_identity() returns trigger language plpgsql set search_path=pace_v2,public as $$
begin
 if tg_op='UPDATE' and (old.broadcast_message_id is distinct from new.broadcast_message_id or old.booking_id is distinct from new.booking_id or old.conversation_id is distinct from new.conversation_id) then raise exception 'journey broadcast delivery identity is immutable'; end if;
 if not exists(select 1 from pace_v2.journey_conversation_messages m join pace_v2.journey_conversations source_conversation on source_conversation.id=m.conversation_id join pace_v2.journey_conversations target_conversation on target_conversation.id=new.conversation_id where m.id=new.broadcast_message_id and m.sender_type='captain_broadcast' and target_conversation.booking_id=new.booking_id and source_conversation.confirmed_allocation_id=target_conversation.confirmed_allocation_id) then raise exception 'broadcast delivery does not belong to its private conversation'; end if;
 return new;
end; $$;
create trigger journey_broadcast_delivery_identity_is_valid before insert or update on pace_v2.journey_broadcast_deliveries for each row execute function pace_v2.validate_journey_broadcast_delivery_identity();

create or replace function pace_v2.assert_journey_conversation_identity(p_conversation_id uuid) returns void language plpgsql set search_path=pace_v2,public as $$
declare v_booking_id uuid; v_allocation_id uuid;
begin
 select booking_id,confirmed_allocation_id into v_booking_id,v_allocation_id from pace_v2.journey_conversations where id=p_conversation_id;
 if not found then return; end if;
 if not exists(select 1 from pace_v2.booking_allocations ba join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id where ba.booking_id=v_booking_id and ca.id=v_allocation_id) then raise exception 'booking allocation change would orphan a journey conversation'; end if;
end; $$;
create or replace function pace_v2.validate_booking_allocation_conversation_change() returns trigger language plpgsql set search_path=pace_v2,public as $$
declare v_booking_id uuid; v_conversation_id uuid;
begin
 if tg_op='DELETE' then v_booking_id:=old.booking_id; else v_booking_id:=new.booking_id; end if;
 for v_conversation_id in select id from pace_v2.journey_conversations where booking_id=v_booking_id loop perform pace_v2.assert_journey_conversation_identity(v_conversation_id); end loop;
 if tg_op='UPDATE' and old.booking_id is distinct from new.booking_id then for v_conversation_id in select id from pace_v2.journey_conversations where booking_id=old.booking_id loop perform pace_v2.assert_journey_conversation_identity(v_conversation_id); end loop; end if;
 if tg_op='DELETE' then return old; end if; return new;
end; $$;
create constraint trigger booking_allocations_preserve_journey_conversation_identity after insert or update or delete on pace_v2.booking_allocations deferrable initially deferred for each row execute function pace_v2.validate_booking_allocation_conversation_change();

create or replace function pace_v2.assert_confirmed_allocation_has_eligible_captain(p_confirmed_allocation_id uuid) returns void language plpgsql set search_path=pace_v2,public as $$
declare v_status text; v_operator_id uuid; v_vehicle_type_id uuid; v_vehicle_active boolean;
begin
 select ca.status,ca.operator_id,v.vehicle_type_id,v.active into v_status,v_operator_id,v_vehicle_type_id,v_vehicle_active
 from pace_v2.confirmed_allocations ca
 join pace_v2.vehicles v on v.id=ca.vehicle_id
 join pace_v2.departures d on d.id=ca.departure_id
 where ca.id=p_confirmed_allocation_id;
 if not found or v_status <> 'confirmed' then return; end if;
 if not v_vehicle_active or not exists(select 1 from pace_v2.captain_assignments a join pace_v2.captains c on c.id=a.captain_id and c.active and c.operator_id=v_operator_id join pace_v2.captain_vehicle_types cvt on cvt.captain_id=c.id and cvt.active and cvt.vehicle_type_id=v_vehicle_type_id where a.confirmed_allocation_id=p_confirmed_allocation_id and a.active) then raise exception 'confirmed allocation requires an active eligible assigned captain'; end if;
end; $$;
create or replace function pace_v2.validate_confirmed_allocation_captain() returns trigger language plpgsql set search_path=pace_v2,public as $$ begin if tg_op='DELETE' then return old; end if; perform pace_v2.assert_confirmed_allocation_has_eligible_captain(new.id); return new; end; $$;
create or replace function pace_v2.validate_captain_assignment_change() returns trigger language plpgsql set search_path=pace_v2,public as $$ begin if tg_op='INSERT' then perform pace_v2.assert_confirmed_allocation_has_eligible_captain(new.confirmed_allocation_id); return new; end if; if tg_op='DELETE' then perform pace_v2.assert_confirmed_allocation_has_eligible_captain(old.confirmed_allocation_id); return old; end if; perform pace_v2.assert_confirmed_allocation_has_eligible_captain(old.confirmed_allocation_id); if old.confirmed_allocation_id is distinct from new.confirmed_allocation_id then perform pace_v2.assert_confirmed_allocation_has_eligible_captain(new.confirmed_allocation_id); end if; return new; end; $$;
create or replace function pace_v2.validate_captain_eligibility_change() returns trigger language plpgsql set search_path=pace_v2,public as $$ declare v_captain_id uuid; v_allocation_id uuid; begin if tg_op<>'INSERT' then v_captain_id:=old.captain_id; for v_allocation_id in select distinct a.confirmed_allocation_id from pace_v2.captain_assignments a where a.captain_id=v_captain_id loop perform pace_v2.assert_confirmed_allocation_has_eligible_captain(v_allocation_id); end loop; end if; if tg_op='INSERT' or old.captain_id is distinct from new.captain_id then v_captain_id:=new.captain_id; for v_allocation_id in select distinct a.confirmed_allocation_id from pace_v2.captain_assignments a where a.captain_id=v_captain_id loop perform pace_v2.assert_confirmed_allocation_has_eligible_captain(v_allocation_id); end loop; end if; if tg_op='DELETE' then return old; end if; return new; end; $$;
create or replace function pace_v2.validate_captain_record_change() returns trigger language plpgsql set search_path=pace_v2,public as $$ declare v_allocation_id uuid; v_captain_id uuid; begin if tg_op='DELETE' then v_captain_id:=old.id; else v_captain_id:=new.id; end if; for v_allocation_id in select distinct a.confirmed_allocation_id from pace_v2.captain_assignments a where a.captain_id=v_captain_id loop perform pace_v2.assert_confirmed_allocation_has_eligible_captain(v_allocation_id); end loop; if tg_op='DELETE' then return old; end if; return new; end; $$;
create or replace function pace_v2.validate_allocated_vehicle_change() returns trigger language plpgsql set search_path=pace_v2,public as $$ declare v_allocation_id uuid; v_vehicle_id uuid; begin if tg_op='DELETE' then v_vehicle_id:=old.id; else v_vehicle_id:=new.id; end if; for v_allocation_id in select id from pace_v2.confirmed_allocations where vehicle_id=v_vehicle_id loop perform pace_v2.assert_confirmed_allocation_has_eligible_captain(v_allocation_id); end loop; if tg_op='DELETE' then return old; end if; return new; end; $$;

create constraint trigger confirmed_allocations_require_eligible_captain after insert or update or delete on pace_v2.confirmed_allocations deferrable initially deferred for each row execute function pace_v2.validate_confirmed_allocation_captain();
create constraint trigger captain_assignments_preserve_eligible_allocation_captain after insert or update or delete on pace_v2.captain_assignments deferrable initially deferred for each row execute function pace_v2.validate_captain_assignment_change();
create constraint trigger captains_preserve_eligible_allocation_captain after insert or update or delete on pace_v2.captains deferrable initially deferred for each row execute function pace_v2.validate_captain_record_change();
create constraint trigger captain_vehicle_types_preserve_eligible_allocation_captain after insert or update or delete on pace_v2.captain_vehicle_types deferrable initially deferred for each row execute function pace_v2.validate_captain_eligibility_change();
create constraint trigger vehicles_preserve_eligible_allocation_captain after insert or update or delete on pace_v2.vehicles deferrable initially deferred for each row execute function pace_v2.validate_allocated_vehicle_change();
revoke all on function pace_v2.prevent_journey_message_mutation(),pace_v2.validate_journey_conversation_identity(),pace_v2.validate_journey_broadcast_delivery_identity(),pace_v2.assert_journey_conversation_identity(uuid),pace_v2.validate_booking_allocation_conversation_change(),pace_v2.assert_confirmed_allocation_has_eligible_captain(uuid),pace_v2.validate_confirmed_allocation_captain(),pace_v2.validate_captain_assignment_change(),pace_v2.validate_captain_eligibility_change(),pace_v2.validate_captain_record_change(),pace_v2.validate_allocated_vehicle_change() from public,anon,authenticated;
