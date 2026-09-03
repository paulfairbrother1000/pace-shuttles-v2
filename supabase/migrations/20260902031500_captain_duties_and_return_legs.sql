create table pace_v2.journey_pairs (
  id uuid primary key default gen_random_uuid(),
  outbound_departure_id uuid not null,
  return_departure_id uuid not null,
  created_at timestamptz not null default now(),
  constraint journey_pairs_distinct_departures_check
    check (outbound_departure_id <> return_departure_id),
  constraint journey_pairs_outbound_departure_unique
    unique (outbound_departure_id) deferrable initially deferred,
  constraint journey_pairs_return_departure_unique
    unique (return_departure_id) deferrable initially deferred,
  constraint journey_pairs_outbound_departure_fkey
    foreign key (outbound_departure_id) references pace_v2.departures(id)
      deferrable initially deferred,
  constraint journey_pairs_return_departure_fkey
    foreign key (return_departure_id) references pace_v2.departures(id)
      deferrable initially deferred
);

alter table pace_v2.departures
  add column journey_pair_id uuid,
  add column leg_number integer,
  add constraint departures_leg_number_check check (leg_number in (1,2)),
  add constraint departures_pairing_shape_check check (
    (journey_pair_id is null and leg_number is null)
    or (journey_pair_id is not null and leg_number is not null)
  ),
  add constraint departures_journey_pair_fkey
    foreign key (journey_pair_id) references pace_v2.journey_pairs(id)
      deferrable initially deferred,
  add constraint departures_one_leg_per_pair_unique
    unique (journey_pair_id,leg_number) deferrable initially deferred;

create index departures_scheduled_departure_ts_idx
  on pace_v2.departures(scheduled_departure_ts);
create index departures_scheduled_arrival_ts_idx
  on pace_v2.departures(scheduled_arrival_ts);
create index departures_local_date_scheduled_ts_idx
  on pace_v2.departures(local_departure_date,scheduled_departure_ts);

create or replace function pace_v2.enforce_journey_pair_consistency()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_pair_ids uuid[]:=array[]::uuid[];
  v_departure_ids uuid[]:=array[]::uuid[];
begin
  if tg_table_name='journey_pairs' then
    if tg_op='INSERT' then
      v_pair_ids:=array[new.id];
      v_departure_ids:=array[new.outbound_departure_id,new.return_departure_id];
    elsif tg_op='DELETE' then
      v_pair_ids:=array[old.id];
      v_departure_ids:=array[old.outbound_departure_id,old.return_departure_id];
    else
      v_pair_ids:=array[old.id,new.id];
      v_departure_ids:=array[
        old.outbound_departure_id,old.return_departure_id,
        new.outbound_departure_id,new.return_departure_id
      ];
    end if;
  elsif tg_op='INSERT' then
    v_pair_ids:=array_remove(array[new.journey_pair_id],null);
    v_departure_ids:=array[new.id];
  elsif tg_op='DELETE' then
    v_pair_ids:=array_remove(array[old.journey_pair_id],null);
    v_departure_ids:=array[old.id];
  else
    v_pair_ids:=array_remove(array[old.journey_pair_id,new.journey_pair_id],null);
    v_departure_ids:=array[old.id,new.id];
  end if;

  select coalesce(array_agg(distinct affected.pair_id),array[]::uuid[])
  into v_pair_ids
  from (
    select existing_ids.pair_id
    from unnest(v_pair_ids) existing_ids(pair_id)
    union all
    select jp.id
    from pace_v2.journey_pairs jp
    where jp.outbound_departure_id=any(v_departure_ids)
       or jp.return_departure_id=any(v_departure_ids)
  ) affected;

  if exists (
    select 1
    from unnest(v_departure_ids) affected(departure_id)
    where (
      select count(*)
      from pace_v2.journey_pairs jp
      where jp.outbound_departure_id=affected.departure_id
         or jp.return_departure_id=affected.departure_id
    ) > 1
  ) then
    raise exception using
      errcode='23505',
      message='a departure cannot belong to more than one journey pair';
  end if;

  if exists (
    select 1
    from pace_v2.journey_pairs jp
    join unnest(v_pair_ids) affected(pair_id) on affected.pair_id=jp.id
    join pace_v2.departures outbound on outbound.id=jp.outbound_departure_id
    join pace_v2.departures return_leg on return_leg.id=jp.return_departure_id
    where outbound.journey_pair_id is distinct from jp.id
       or outbound.leg_number is distinct from 1
       or return_leg.journey_pair_id is distinct from jp.id
       or return_leg.leg_number is distinct from 2
  ) then
    raise exception using
      errcode='23514',
      message='each journey pair must contain its outbound leg 1 and return leg 2';
  end if;

  if exists (
    select 1
    from pace_v2.departures d
    where d.journey_pair_id=any(v_pair_ids)
      and not exists (
        select 1
        from pace_v2.journey_pairs jp
        where jp.id=d.journey_pair_id
          and (
            (d.leg_number=1 and jp.outbound_departure_id=d.id)
            or (d.leg_number=2 and jp.return_departure_id=d.id)
          )
      )
  ) then
    raise exception using
      errcode='23514',
      message='paired departure metadata must match its journey pair';
  end if;

  return null;
end
$$;

alter function pace_v2.enforce_journey_pair_consistency() owner to postgres;

create constraint trigger journey_pairs_consistency_check
after insert or update or delete on pace_v2.journey_pairs
deferrable initially deferred
for each row execute function pace_v2.enforce_journey_pair_consistency();

create constraint trigger departures_journey_pair_consistency_check
after insert or delete or update of journey_pair_id,leg_number on pace_v2.departures
deferrable initially deferred
for each row execute function pace_v2.enforce_journey_pair_consistency();

create or replace function pace_v2.enforce_journey_pair_has_site_admin_access()
returns trigger
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_pairing_changed boolean;
begin
  if tg_table_name='journey_pairs' then
    v_pairing_changed:=true;
  elsif tg_op='INSERT' then
    v_pairing_changed:=new.journey_pair_id is not null or new.leg_number is not null;
  elsif tg_op='DELETE' then
    v_pairing_changed:=old.journey_pair_id is not null or old.leg_number is not null;
  else
    v_pairing_changed:=new.journey_pair_id is distinct from old.journey_pair_id
      or new.leg_number is distinct from old.leg_number;
  end if;

  if v_pairing_changed
     and coalesce(current_setting('pace_v2.journey_pair_mutation_authorized',true),'')<>'on' then
    raise exception using
      errcode='42501',
      message='journey pairing may only change through protected lifecycle functions';
  end if;

  if tg_op='DELETE' then return old; end if;
  return new;
end
$$;

create trigger journey_pairs_site_admin_mutation_check
before insert or update or delete on pace_v2.journey_pairs
for each row execute function pace_v2.enforce_journey_pair_has_site_admin_access();

create trigger departures_pairing_site_admin_mutation_check
before insert or update or delete on pace_v2.departures
for each row execute function pace_v2.enforce_journey_pair_has_site_admin_access();

alter table pace_v2.journey_pairs enable row level security;
revoke all on table pace_v2.journey_pairs from public,anon,authenticated;
grant select on table pace_v2.journey_pairs to authenticated;
revoke insert,update,delete on table pace_v2.journey_pairs from authenticated;

create policy journey_pairs_site_admin_select
on pace_v2.journey_pairs for select
to authenticated
using (pace_v2.is_site_admin());

create policy journey_pairs_site_admin_insert
on pace_v2.journey_pairs for insert
to authenticated
with check (pace_v2.is_site_admin());

create policy journey_pairs_site_admin_update
on pace_v2.journey_pairs for update
to authenticated
using (pace_v2.is_site_admin())
with check (pace_v2.is_site_admin());

create policy journey_pairs_site_admin_delete
on pace_v2.journey_pairs for delete
to authenticated
using (pace_v2.is_site_admin());

revoke all on function pace_v2.enforce_journey_pair_consistency() from public,anon,authenticated;
revoke all on function pace_v2.enforce_journey_pair_has_site_admin_access() from public;

comment on table pace_v2.journey_pairs is
  'Explicit Site Admin-defined pairing of two departure legs into one commercial duty.';
comment on column pace_v2.departures.journey_pair_id is
  'Null for legacy one-way journeys; otherwise identifies the shared two-leg duty.';
comment on column pace_v2.departures.leg_number is
  'Null for legacy one-way journeys; 1 for outbound and 2 for return.';


-- Return design belongs to the recurring service.  Pickups and destinations
-- are separate entity domains, so a Site Admin must select the operational
-- return route explicitly; this migration never compares their UUIDs.
create table pace_v2.service_return_designs (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null unique references pace_v2.services(id) on delete cascade,
  reverse_route_id uuid not null references pace_v2.routes(id),
  return_local_time time not null,
  return_duration_minutes integer not null check (return_duration_minutes>0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table pace_v2.service_return_designs enable row level security;
revoke all on table pace_v2.service_return_designs from public,anon,authenticated;

create table pace_v2.route_return_mappings (
  outbound_route_id uuid primary key references pace_v2.routes(id) on delete cascade,
  return_route_id uuid not null references pace_v2.routes(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint route_return_mappings_distinct_routes check (outbound_route_id<>return_route_id),
  unique (outbound_route_id),
  unique (return_route_id)
);
alter table pace_v2.route_return_mappings enable row level security;
revoke all on table pace_v2.route_return_mappings from public,anon,authenticated;
create or replace function pace_v2.enforce_route_return_mapping_admin()
returns trigger language plpgsql security invoker set search_path='' as $$
declare v_route_ids uuid[];v_service_id uuid;v_outbound pace_v2.routes%rowtype;v_return pace_v2.routes%rowtype;
begin
  if not pace_v2.is_site_admin() then raise exception using errcode='42501',message='return route mapping requires Site Admin'; end if;
  if tg_op='UPDATE' and new.outbound_route_id is not distinct from old.outbound_route_id and new.return_route_id is not distinct from old.return_route_id then return new; end if;
  if tg_op<>'DELETE' then
    select * into v_outbound from pace_v2.routes where id=new.outbound_route_id and is_active for share;
    select * into v_return from pace_v2.routes where id=new.return_route_id and is_active for share;
    if v_outbound.id is null or v_return.id is null or v_outbound.id=v_return.id or v_outbound.country_id is distinct from v_return.country_id then
      raise exception using errcode='22023',message='return route mapping requires active, distinct same-country routes';
    end if;
  end if;
  if tg_op='DELETE' then
    v_route_ids:=array[old.outbound_route_id];
  elsif tg_op='INSERT' then
    v_route_ids:=array[new.outbound_route_id];
  else
    v_route_ids:=array[old.outbound_route_id,new.outbound_route_id];
  end if;
  -- The mapping lifecycle uses the exact service/design lock protocol as save
  -- and materialization. A live design is immutable until it is disabled.
  for v_service_id in
    select s.id from pace_v2.services s where s.route_id=any(v_route_ids) order by s.id for update
  loop
    perform pg_advisory_xact_lock(hashtextextended('service-return-design:'||v_service_id::text,0));
    if exists(select 1 from pace_v2.service_return_designs d where d.service_id=v_service_id) then
      raise exception using errcode='22023',message='return route mapping cannot change while a service return design is enabled; disable the design first';
    end if;
  end loop;
  return coalesce(new,old);
end $$;
create trigger route_return_mappings_admin_mutation before insert or update or delete on pace_v2.route_return_mappings for each row execute function pace_v2.enforce_route_return_mapping_admin();
create or replace function public.v2_admin_save_route_return_mapping(p_outbound_route_id uuid,p_return_route_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_outbound pace_v2.routes%rowtype;v_return pace_v2.routes%rowtype;
begin
  if not pace_v2.is_site_admin() then raise exception using errcode='42501',message='site admin required';end if;
  select * into v_outbound from pace_v2.routes where id=p_outbound_route_id and is_active for share;
  select * into v_return from pace_v2.routes where id=p_return_route_id and is_active for share;
  if v_outbound.id is null or v_return.id is null or v_outbound.id=v_return.id or v_outbound.country_id is distinct from v_return.country_id then raise exception using errcode='22023',message='active, distinct same-country routes are required';end if;
  -- A no-op must not enter the INSERT path: its BEFORE INSERT lifecycle
  -- trigger correctly rejects mapping changes while a design is enabled.
  if exists(select 1 from pace_v2.route_return_mappings m where m.outbound_route_id=v_outbound.id and m.return_route_id=v_return.id) then return; end if;
  insert into pace_v2.route_return_mappings(outbound_route_id,return_route_id) values(v_outbound.id,v_return.id)
  on conflict(outbound_route_id) do update set return_route_id=excluded.return_route_id;
end $$;
create function public.v2_admin_route_return_mapping_options(p_service_id uuid)
returns table(outbound_route_id uuid,outbound_route_name text,mapped_return_route_id uuid,eligible_return_routes jsonb)
language sql stable security definer set search_path='' as $$
  select outbound.id,
    coalesce(outbound.route_name,outbound.name),
    mapping.return_route_id,
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',candidate.id,
          'route_name',coalesce(candidate.route_name,candidate.name),
          'is_active',candidate.is_active
        ) order by coalesce(candidate.route_name,candidate.name),candidate.id
      )
      from pace_v2.routes candidate
      where candidate.is_active
        and candidate.country_id=outbound.country_id
        and candidate.id<>outbound.id
        and (
          candidate.id=mapping.return_route_id
          or not exists(
            select 1 from pace_v2.route_return_mappings claimed
            where claimed.return_route_id=candidate.id
              and claimed.outbound_route_id<>outbound.id
          )
        )
    ),'[]'::jsonb)
  from pace_v2.services service
  join pace_v2.routes outbound on outbound.id=service.route_id and outbound.is_active
  left join pace_v2.route_return_mappings mapping on mapping.outbound_route_id=outbound.id
  where service.id=p_service_id and pace_v2.is_site_admin()
$$;
revoke all on function public.v2_admin_save_route_return_mapping(uuid,uuid) from public,anon;
revoke all on function public.v2_admin_route_return_mapping_options(uuid) from public,anon;
grant execute on function public.v2_admin_save_route_return_mapping(uuid,uuid) to authenticated;
grant execute on function public.v2_admin_route_return_mapping_options(uuid) to authenticated;

alter table pace_v2.departures add column if not exists actual_departure_ts timestamptz;
alter table pace_v2.departures add column is_commercial boolean not null default true;
update pace_v2.departures set is_commercial=false where leg_number=2;
drop index if exists pace_v2.ux_departures_service_local_date;
create unique index ux_departures_service_local_date
  on pace_v2.departures(service_id,local_departure_date)
  where is_commercial;
alter table pace_v2.departures add constraint departures_return_leg_noncommercial_check
  check (leg_number is distinct from 2 or is_commercial=false);
create index departures_commercial_schedule_idx on pace_v2.departures(is_commercial,scheduled_departure_ts);

create or replace function pace_v2.reject_noncommercial_departure_use()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from pace_v2.departures d where d.id=new.departure_id and not d.is_commercial) then
    raise exception using errcode='22023',message='paired return legs are operational only and cannot be booked or allocated';
  end if;
  return new;
end $$;
create trigger bookings_reject_noncommercial_departure before insert or update of departure_id on pace_v2.bookings for each row execute function pace_v2.reject_noncommercial_departure_use();
create trigger vehicle_considerations_reject_noncommercial_departure before insert or update of departure_id on pace_v2.vehicle_considerations for each row execute function pace_v2.reject_noncommercial_departure_use();
create trigger confirmed_allocations_reject_noncommercial_departure before insert or update of departure_id on pace_v2.confirmed_allocations for each row execute function pace_v2.reject_noncommercial_departure_use();

-- A dated commercial departure is materializable only when it still exactly
-- represents the active service design. Save and the insert trigger share this
-- predicate so stale, cancelled, off-pattern or local-time-mismatched rows
-- cannot gain a Leg 2.
create or replace function pace_v2.is_qualified_service_departure(p_service_id uuid,p_departure_id uuid,p_outbound_local_time time)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1
    from pace_v2.departures d
    join pace_v2.services s on s.id=d.service_id and s.active
    join pace_v2.routes r on r.id=s.route_id and r.is_active
    where s.id=p_service_id and d.id=p_departure_id and d.service_id=s.id and d.route_id=s.route_id and d.is_commercial
      and d.status='scheduled' and d.scheduled_departure_ts>now()
      and d.local_departure_date>=coalesce(s.valid_from,(now() at time zone s.timezone)::date)
      and (s.valid_to is null or d.local_departure_date<=s.valid_to)
      and extract(dow from d.local_departure_date)::smallint=any(s.days_of_week)
      and (coalesce(s.recurrence_type,'weekly')<>'weekly' or ((d.local_departure_date-coalesce(s.recurrence_anchor_date,s.valid_from,(now() at time zone s.timezone)::date))/7)%greatest(coalesce(s.recurrence_interval_weeks,1),1)=0)
      and (d.scheduled_departure_ts at time zone s.timezone)::date=d.local_departure_date
      and (d.scheduled_departure_ts at time zone s.timezone)::time=p_outbound_local_time
  )
$$;

-- Serialize generated commercial inserts with Site Admin schedule edits before
-- the row can become visible to the AFTER INSERT return-leg materializer. The
-- stable serialization error tells the generator to recompute from the current
-- service design instead of publishing a stale occurrence.
create or replace function pace_v2.guard_service_departure_insert()
returns trigger language plpgsql security definer set search_path='' as $$
declare
  v_service pace_v2.services%rowtype;
  v_today date;
  v_anchor date;
begin
  if not (new.is_commercial and new.service_id is not null and new.status='scheduled' and new.scheduled_departure_ts>now()) then
    return new;
  end if;

  -- Global lock order: service row -> service-design advisory -> departure
  -- advisory/row. The INSERT has no row to lock yet, so its stable UUID is the
  -- departure-level serialization key used by save/materialization.
  select service.* into v_service
  from pace_v2.services service where service.id=new.service_id for update;
  if v_service.id is null then
    raise exception using errcode='40001',message='stale generated departure schedule; retry generation';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('service-return-design:'||v_service.id::text,0));
  perform pg_advisory_xact_lock(hashtextextended(new.id::text,0));

  if not v_service.active
     or not exists(select 1 from pg_catalog.pg_timezone_names timezone_name where timezone_name.name=v_service.timezone) then
    raise exception using errcode='40001',message='stale generated departure schedule; retry generation';
  end if;
  v_today:=(now() at time zone v_service.timezone)::date;
  v_anchor:=coalesce(v_service.recurrence_anchor_date,v_service.valid_from,v_today);
  if not exists(select 1 from pace_v2.routes route where route.id=v_service.route_id and route.is_active)
     or new.route_id is distinct from v_service.route_id
     or new.trip_timezone is distinct from v_service.timezone
     or new.local_departure_date is distinct from (new.scheduled_departure_ts at time zone v_service.timezone)::date
     or (new.scheduled_departure_ts at time zone v_service.timezone)::time is distinct from v_service.departure_time
     or new.local_departure_date<coalesce(v_service.valid_from,v_today)
     or (v_service.valid_to is not null and new.local_departure_date>v_service.valid_to)
     or coalesce(cardinality(v_service.days_of_week),0)=0
     or extract(dow from new.local_departure_date)::smallint<>all(v_service.days_of_week)
     or (
       coalesce(v_service.recurrence_type,'weekly')='weekly'
       and ((new.local_departure_date-v_anchor)/7)%greatest(coalesce(v_service.recurrence_interval_weeks,1),1)<>0
     ) then
    raise exception using errcode='40001',message='stale generated departure schedule; retry generation';
  end if;
  return new;
end $$;
create trigger departures_guard_service_schedule before insert on pace_v2.departures
for each row execute function pace_v2.guard_service_departure_insert();
revoke all on function pace_v2.guard_service_departure_insert() from public,anon,authenticated;

-- This bounded arithmetic calculation considers at most the configured days
-- of week. It has defined null fallbacks and never scans an arbitrary window.
create or replace function pace_v2.next_service_operating_date(p_service_id uuid,p_outbound_local_time time)
returns date language plpgsql stable security definer set search_path='' as $$
declare v_service pace_v2.services%rowtype;v_today date;v_start date;v_anchor date;v_candidate date;v_next date;v_dow smallint;v_weeks bigint;v_interval bigint;v_shift_days bigint;
begin
  select * into v_service from pace_v2.services where id=p_service_id;
  if v_service.id is null or p_outbound_local_time is null or not exists(select 1 from pg_timezone_names where name=v_service.timezone) then return null; end if;
  v_today:=(now() at time zone v_service.timezone)::date;
  v_anchor:=coalesce(v_service.recurrence_anchor_date,v_service.valid_from);
  v_start:=greatest(coalesce(v_service.valid_from,v_today),v_today,coalesce(v_anchor,v_today));
  if ((v_start::timestamp+p_outbound_local_time) at time zone v_service.timezone)<=now() then v_start:=v_start+1; end if;
  v_interval:=greatest(coalesce(v_service.recurrence_interval_weeks,1),1)::bigint;
  foreach v_dow in array coalesce(v_service.days_of_week,array[]::smallint[]) loop
    v_candidate:=v_start+((v_dow-extract(dow from v_start)::smallint+7)%7);
    if coalesce(v_service.recurrence_type,'weekly')='weekly' and v_anchor is not null then
      v_weeks:=(v_candidate-v_anchor)::bigint/7;
      v_shift_days:=mod(v_interval-mod(v_weeks,v_interval),v_interval)*7;
      -- Date addition accepts an integer day count.  A recurrence so distant
      -- that its next occurrence is outside PostgreSQL's representable date
      -- range has no usable next date; do not overflow or fall back to a scan.
      if v_shift_days>2147483647 then continue; end if;
      if v_service.valid_to is not null and (v_candidate>v_service.valid_to or v_shift_days>(v_service.valid_to-v_candidate)::bigint) then continue; end if;
      begin
        v_candidate:=v_candidate+v_shift_days::integer;
      exception when datetime_field_overflow then
        continue;
      end;
    end if;
    if v_service.valid_to is null or v_candidate<=v_service.valid_to then
      v_next:=case when v_next is null or v_candidate<v_next then v_candidate else v_next end;
    end if;
  end loop;
  return v_next;
end $$;

create or replace function pace_v2.materialize_service_return_leg(p_outbound_departure_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  v_service_id uuid;
  v_service pace_v2.services%rowtype;
  v_outbound pace_v2.departures%rowtype;
  v_design pace_v2.service_return_designs%rowtype;
  v_route pace_v2.routes%rowtype;
  v_pair pace_v2.journey_pairs%rowtype;
  v_return pace_v2.departures%rowtype;
  v_return_id uuid;
  v_pair_id uuid;
  v_return_ts timestamptz;
  v_requires_update boolean;
begin
  select service_id into v_service_id from pace_v2.departures where id=p_outbound_departure_id;
  if v_service_id is null then return null; end if;
  -- Shared lock order: service row, service-design advisory lock, departure row.
  select * into v_service from pace_v2.services where id=v_service_id for update;
  perform pg_advisory_xact_lock(hashtextextended('service-return-design:'||v_service.id::text,0));
  select * into v_outbound from pace_v2.departures where id=p_outbound_departure_id for update;
  if v_outbound.id is null or not pace_v2.is_qualified_service_departure(v_service.id,v_outbound.id,v_service.departure_time) then return null; end if;
  if v_outbound.journey_pair_id is not null then
    select * into v_pair from pace_v2.journey_pairs
    where id=v_outbound.journey_pair_id for update;
    if v_pair.id is null or v_pair.outbound_departure_id is distinct from v_outbound.id then
      raise exception using errcode='23514',message='paired departure metadata must match its journey pair';
    end if;
    v_return_id:=v_pair.return_departure_id;
    select * into v_return from pace_v2.departures where id=v_return_id for update;
    if v_return.id is null
       or v_return.journey_pair_id is distinct from v_pair.id
       or v_return.leg_number is distinct from 2
       or v_return.is_commercial then
      raise exception using errcode='23514',message='paired departure metadata must match its journey pair';
    end if;
  end if;
  select * into v_design from pace_v2.service_return_designs where service_id=v_outbound.service_id for key share;
  if v_design.id is null then return null; end if;
  select r.* into v_route from pace_v2.route_return_mappings m join pace_v2.routes r on r.id=m.return_route_id and r.is_active where m.outbound_route_id=v_service.route_id and m.return_route_id=v_design.reverse_route_id for share of r;
  if v_route.id is null or not exists(select 1 from pg_timezone_names where name=v_route.trip_timezone) then
    raise exception using errcode='22023',message='saved return route must be mapped to the service route, active, and have a valid timezone';
  end if;
  v_return_ts:=(v_outbound.local_departure_date::timestamp+v_design.return_local_time) at time zone v_route.trip_timezone;
  -- PostgreSQL resolves an overlap to its standard-time occurrence; reject a
  -- nonexistent local wall time by round-tripping it through the route zone.
  if (v_return_ts at time zone v_route.trip_timezone)::date is distinct from v_outbound.local_departure_date
     or (v_return_ts at time zone v_route.trip_timezone)::time is distinct from v_design.return_local_time then
    raise exception using errcode='22023',message='return local time does not exist in the return route timezone';
  end if;
  if v_return_ts<=v_outbound.scheduled_arrival_ts then
    raise exception using errcode='22023',message='return departure must be after outbound arrival';
  end if;
  if v_pair.id is not null then
    v_requires_update:=
      v_return.route_id is distinct from v_route.id
      or v_return.scheduled_departure_ts is distinct from v_return_ts
      or v_return.scheduled_arrival_ts is distinct from v_return_ts+make_interval(mins=>v_design.return_duration_minutes)
      or v_return.trip_timezone is distinct from v_route.trip_timezone
      or v_return.local_departure_date is distinct from v_outbound.local_departure_date
      or v_return.t72_ts is distinct from v_return_ts-make_interval(hours=>coalesce(v_route.t72_hours,72))
      or v_return.t24_ts is distinct from v_return_ts-make_interval(hours=>coalesce(v_route.t24_hours,24));
    if v_requires_update and (
      exists(select 1 from pace_v2.bookings booking where booking.departure_id=v_outbound.id)
      or exists(
        select 1 from pace_v2.booking_allocations booking_allocation
        join pace_v2.vehicle_considerations consideration
          on consideration.id=booking_allocation.vehicle_consideration_id
        where consideration.departure_id=v_outbound.id
      )
      or exists(select 1 from pace_v2.confirmed_allocations allocation where allocation.departure_id=v_outbound.id)
      or exists(
        select 1 from pace_v2.voyage_logs voyage
        join pace_v2.confirmed_allocations allocation
          on allocation.id=voyage.confirmed_allocation_id
        where allocation.departure_id=v_outbound.id
      )
      or exists(
        select 1 from pace_v2.captain_leg_operations operation
        where operation.departure_id in(v_outbound.id,v_return.id)
      )
      or exists(
        select 1 from pace_v2.departures departure
        where departure.id in(v_outbound.id,v_return.id)
          and (
            departure.actual_departure_ts is not null
            or departure.actual_arrival_ts is not null
            or departure.status<>'scheduled'
          )
      )
    ) then
      raise exception using
        errcode='22023',
        message='return journey design cannot change after bookings, allocations or operation evidence exist';
    end if;
    if v_requires_update then
      update pace_v2.departures
      set route_id=v_route.id,
          scheduled_departure_ts=v_return_ts,
          scheduled_arrival_ts=v_return_ts+make_interval(mins=>v_design.return_duration_minutes),
          trip_timezone=v_route.trip_timezone,
          local_departure_date=v_outbound.local_departure_date,
          t72_ts=v_return_ts-make_interval(hours=>coalesce(v_route.t72_hours,72)),
          t24_ts=v_return_ts-make_interval(hours=>coalesce(v_route.t24_hours,24))
      where id=v_return_id;
    end if;
    return v_return_id;
  end if;
  insert into pace_v2.departures(service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial)
  values(v_outbound.service_id,v_route.id,v_return_ts,v_return_ts+make_interval(mins=>v_design.return_duration_minutes),v_route.trip_timezone,v_outbound.local_departure_date,v_return_ts-make_interval(hours=>coalesce(v_route.t72_hours,72)),v_return_ts-make_interval(hours=>coalesce(v_route.t24_hours,24)),'scheduled',false)
  returning id into v_return_id;
  perform set_config('pace_v2.journey_pair_mutation_authorized','on',true);
  insert into pace_v2.journey_pairs(outbound_departure_id,return_departure_id) values(v_outbound.id,v_return_id) returning id into v_pair_id;
  update pace_v2.departures set journey_pair_id=v_pair_id,leg_number=case when id=v_outbound.id then 1 else 2 end where id in(v_outbound.id,v_return_id);
  perform set_config('pace_v2.journey_pair_mutation_authorized','off',true);
  return v_return_id;
end $$;

create or replace function pace_v2.materialize_service_return_after_departure()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.is_commercial and new.service_id is not null and new.journey_pair_id is null then
    perform pace_v2.materialize_service_return_leg(new.id);
  end if;
  return new;
end $$;
create trigger departures_materialize_service_return after insert on pace_v2.departures for each row execute function pace_v2.materialize_service_return_after_departure();

create function pace_v2.admin_save_paired_journey_design(
  p_service_id uuid,p_outbound_local_time time,p_return_enabled boolean,p_return_local_time time default null,p_return_duration_minutes integer default null,p_reverse_route_id uuid default null
) returns table(journey_pair_id uuid,outbound_departure_id uuid,return_departure_id uuid,updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare
  v_service pace_v2.services%rowtype;
  v_outbound_route pace_v2.routes%rowtype;
  v_return_route pace_v2.routes%rowtype;
  v_design pace_v2.service_return_designs%rowtype;
  v_existing_design pace_v2.service_return_designs%rowtype;
  v_outbound pace_v2.departures%rowtype;
  v_return_departure pace_v2.departures%rowtype;
  v_return_id uuid;
  v_pair_id uuid;
  v_outbound_id uuid;
  v_operating_date date;
  v_outbound_ts timestamptz;
  v_return_ts timestamptz;
  v_outbound_arrival_ts timestamptz;
  v_prior_outbound_time time;
  v_outbound_time_changed boolean;
  v_first_return_enable boolean;
  v_return_settings_changed boolean:=false;
  v_affected_outbound_ids uuid[]:=array[]::uuid[];
  v_design_edit_ids uuid[]:=array[]::uuid[];
begin
  if not pace_v2.is_site_admin() then raise exception using errcode='42501',message='site admin required';end if;
  if p_service_id is null or p_outbound_local_time is null then raise exception using errcode='22023',message='outbound service and local time are required';end if;
  select * into v_service from pace_v2.services where id=p_service_id for update;
  if v_service.id is null then raise exception using errcode='22023',message='outbound service required';end if;
  -- All design mutations and materialization acquire these first, in order.
  perform pg_advisory_xact_lock(hashtextextended('service-return-design:'||v_service.id::text,0));
  v_prior_outbound_time:=v_service.departure_time;
  v_outbound_time_changed:=v_prior_outbound_time is distinct from p_outbound_local_time;
  select * into v_outbound_route from pace_v2.routes where id=v_service.route_id for share;
  if v_outbound_route.id is null then raise exception using errcode='22023',message='outbound route required';end if;
  if (v_outbound_time_changed or coalesce(p_return_enabled,false))
     and not exists(select 1 from pg_timezone_names where name=v_service.timezone) then
    raise exception using errcode='22023',message='outbound service with a valid timezone required';
  end if;

  select * into v_existing_design from pace_v2.service_return_designs
  where service_id=v_service.id for update;
  v_first_return_enable:=v_existing_design.id is null and coalesce(p_return_enabled,false);
  if coalesce(p_return_enabled,false) then
    if not v_service.active or not v_outbound_route.is_active then raise exception using errcode='22023',message='active outbound service and route required';end if;
    if p_return_local_time is null or p_return_duration_minutes is null or p_return_duration_minutes<=0 or p_reverse_route_id is null then raise exception using errcode='22023',message='return route, local time and positive duration are required';end if;
    select r.* into v_return_route from pace_v2.route_return_mappings m join pace_v2.routes r on r.id=m.return_route_id and r.is_active where m.outbound_route_id=v_outbound_route.id and m.return_route_id=p_reverse_route_id for share of r;
    if v_return_route.id is null or not exists(select 1 from pg_timezone_names where name=v_return_route.trip_timezone) then raise exception using errcode='22023',message='selected p_reverse_route_id is mapped as the service route return, active, and has a valid timezone';end if;
  end if;
  v_return_settings_changed:=v_existing_design.id is not null and (
    v_existing_design.reverse_route_id is distinct from v_return_route.id
    or v_existing_design.return_local_time is distinct from p_return_local_time
    or v_existing_design.return_duration_minutes is distinct from p_return_duration_minutes
  );

  -- Capture generated instances against the prior recurring identity before
  -- either the service schedule or any departure timestamp is changed. Status
  -- is deliberately not part of the identity: non-pristine instances must be
  -- found and rejected rather than silently excluded.
  if v_outbound_time_changed then
    select coalesce(array_agg(candidate.id order by candidate.scheduled_departure_ts,candidate.id),array[]::uuid[])
      into v_affected_outbound_ids
    from (
      select d.id,d.scheduled_departure_ts
      from pace_v2.departures d
      where d.service_id=v_service.id and d.route_id=v_service.route_id and d.is_commercial
        and d.scheduled_departure_ts>now()
        and d.local_departure_date>=coalesce(v_service.valid_from,(now() at time zone v_service.timezone)::date)
        and (v_service.valid_to is null or d.local_departure_date<=v_service.valid_to)
        and extract(dow from d.local_departure_date)::smallint=any(v_service.days_of_week)
        and (coalesce(v_service.recurrence_type,'weekly')<>'weekly' or ((d.local_departure_date-coalesce(v_service.recurrence_anchor_date,v_service.valid_from,(now() at time zone v_service.timezone)::date))/7)%greatest(coalesce(v_service.recurrence_interval_weeks,1),1)=0)
        and (d.scheduled_departure_ts at time zone v_service.timezone)::date=d.local_departure_date
        and (d.scheduled_departure_ts at time zone v_service.timezone)::time=v_prior_outbound_time
    ) candidate;
  end if;

  -- Return-only edits retain their all-instance protection. Outbound edits add
  -- every prior-schedule instance, including one-way departures. All locks and
  -- protection checks complete before the first design mutation.
  select coalesce(array_agg(candidate.id order by candidate.scheduled_departure_ts,candidate.id),array[]::uuid[])
    into v_design_edit_ids
  from (
    select d.id,d.scheduled_departure_ts
    from pace_v2.departures d
    where d.id=any(v_affected_outbound_ids)
    union
    select d.id,d.scheduled_departure_ts
    from pace_v2.departures d
    where (not coalesce(p_return_enabled,false) or v_return_settings_changed or v_first_return_enable)
      and d.service_id=v_service.id and d.is_commercial
      and d.scheduled_departure_ts>now()
      and (v_first_return_enable or d.journey_pair_id is not null)
  ) candidate;

  foreach v_outbound_id in array v_design_edit_ids loop
    perform pg_advisory_xact_lock(hashtextextended(v_outbound_id::text,0));
    select * into v_outbound from pace_v2.departures where id=v_outbound_id for update;
    v_return_id:=null;
    v_return_departure:=null;
    if v_first_return_enable and v_outbound.journey_pair_id is not null then
      raise exception using
        errcode='22023',
        message='return journey cannot be enabled after bookings, allocations, active quotes, pairs or operation evidence exist';
    elsif v_outbound.journey_pair_id is not null then
      select pair.return_departure_id into v_return_id
      from pace_v2.journey_pairs pair where pair.id=v_outbound.journey_pair_id for update;
      select * into v_return_departure from pace_v2.departures where id=v_return_id for update;
      if v_return_departure.id is null then raise exception using errcode='23514',message='paired departure metadata must match its journey pair';end if;
    end if;
    if exists(select 1 from pace_v2.bookings booking where booking.departure_id=v_outbound.id)
       or exists(
         select 1 from pace_v2.booking_allocations booking_allocation
         join pace_v2.vehicle_considerations consideration on consideration.id=booking_allocation.vehicle_consideration_id
         where consideration.departure_id=v_outbound.id
       )
       or exists(select 1 from pace_v2.confirmed_allocations allocation where allocation.departure_id=v_outbound.id)
       or exists(
         select 1 from pace_v2.voyage_logs voyage
         join pace_v2.confirmed_allocations allocation on allocation.id=voyage.confirmed_allocation_id
         where allocation.departure_id=v_outbound.id
       )
       or exists(select 1 from pace_v2.captain_leg_operations operation where operation.departure_id in(v_outbound.id,v_return_id))
       or ((v_outbound_time_changed or v_first_return_enable) and exists(
         select 1 from pace_v2.quote_intents quote where quote.departure_id=v_outbound.id and quote.expires_at>now()
       ))
       or (not v_first_return_enable and v_outbound.status<>'scheduled')
       or v_outbound.actual_departure_ts is not null
       or v_outbound.actual_arrival_ts is not null
       or (v_return_departure.id is not null and (
         v_return_departure.status<>'scheduled'
         or v_return_departure.actual_departure_ts is not null
         or v_return_departure.actual_arrival_ts is not null
       )) then
      if v_first_return_enable then
        raise exception using errcode='22023',message='return journey cannot be enabled after bookings, allocations, active quotes, pairs or operation evidence exist';
      elsif v_outbound_time_changed and v_outbound.id=any(v_affected_outbound_ids) then
        raise exception using errcode='22023',message='outbound journey time cannot change after bookings, allocations or operation evidence exist';
      elsif not coalesce(p_return_enabled,false) then
        raise exception using errcode='22023',message='return journey cannot be removed after bookings, allocations or operation evidence exist';
      else
        raise exception using errcode='22023',message='return journey design cannot change after bookings, allocations or operation evidence exist';
      end if;
    end if;
  end loop;

  -- Recompute each pristine instance from its local operating date. This is the
  -- same timezone/DST round-trip and route-duration arithmetic used by normal
  -- generation, while preserving departure and pair identities.
  if v_outbound_time_changed then
    foreach v_outbound_id in array v_affected_outbound_ids loop
      select * into v_outbound from pace_v2.departures where id=v_outbound_id;
      v_outbound_ts:=(v_outbound.local_departure_date::timestamp+p_outbound_local_time) at time zone v_service.timezone;
      if (v_outbound_ts at time zone v_service.timezone)::date is distinct from v_outbound.local_departure_date
         or (v_outbound_ts at time zone v_service.timezone)::time is distinct from p_outbound_local_time
         or v_outbound_ts<=now() then
        raise exception using errcode='22023',message='outbound local time does not exist or is not future in its operating timezone';
      end if;
      v_outbound_arrival_ts:=v_outbound_ts+make_interval(mins=>coalesce(v_outbound_route.approx_duration_mins,60));
      update pace_v2.departures
      set scheduled_departure_ts=v_outbound_ts,
          scheduled_arrival_ts=v_outbound_arrival_ts,
          local_departure_date=(v_outbound_ts at time zone v_service.timezone)::date,
          t72_ts=v_outbound_ts-make_interval(hours=>coalesce(v_outbound_route.t72_hours,72)),
          t24_ts=v_outbound_ts-make_interval(hours=>coalesce(v_outbound_route.t24_hours,24))
      where id=v_outbound_id;
    end loop;
  end if;
  update pace_v2.services
  set departure_time=p_outbound_local_time
  where id=v_service.id and departure_time is distinct from p_outbound_local_time;

  if not coalesce(p_return_enabled,false) then
    for v_outbound_id in
      select d.id from pace_v2.departures d
      where d.service_id=v_service.id and d.is_commercial
        and d.scheduled_departure_ts>now() and d.journey_pair_id is not null
      order by d.scheduled_departure_ts,d.id
    loop
      select * into v_outbound from pace_v2.departures where id=v_outbound_id;
      select pair.return_departure_id into v_return_id from pace_v2.journey_pairs pair where pair.id=v_outbound.journey_pair_id;
      perform set_config('pace_v2.journey_pair_mutation_authorized','on',true);
      update pace_v2.departures set journey_pair_id=null,leg_number=null where id in(v_outbound.id,v_return_id);
      delete from pace_v2.journey_pairs where id=v_outbound.journey_pair_id;
      delete from pace_v2.departures where id=v_return_id;
      perform set_config('pace_v2.journey_pair_mutation_authorized','off',true);
    end loop;
    delete from pace_v2.service_return_designs where service_id=v_service.id;
    journey_pair_id:=null;outbound_departure_id:=null;return_departure_id:=null;updated_at:=now();return next;return;
  end if;

  select min(d.local_departure_date) into v_operating_date
  from pace_v2.departures d
  where d.service_id=v_service.id
    and pace_v2.is_qualified_service_departure(v_service.id,d.id,p_outbound_local_time);
  if v_operating_date is null then v_operating_date:=pace_v2.next_service_operating_date(v_service.id,p_outbound_local_time);end if;
  if v_operating_date is null then raise exception using errcode='22023',message='service has no valid recurring operating date for return validation';end if;
  v_outbound_ts:=(v_operating_date::timestamp+p_outbound_local_time) at time zone v_service.timezone;
  v_return_ts:=(v_operating_date::timestamp+p_return_local_time) at time zone v_return_route.trip_timezone;
  if (v_outbound_ts at time zone v_service.timezone)::date is distinct from v_operating_date or (v_outbound_ts at time zone v_service.timezone)::time is distinct from p_outbound_local_time or (v_return_ts at time zone v_return_route.trip_timezone)::date is distinct from v_operating_date or (v_return_ts at time zone v_return_route.trip_timezone)::time is distinct from p_return_local_time then raise exception using errcode='22023',message='outbound or return local time does not exist in its operating timezone';end if;
  v_outbound_arrival_ts:=v_outbound_ts+make_interval(mins=>coalesce(v_outbound_route.approx_duration_mins,60));
  if v_return_ts<=v_outbound_arrival_ts then raise exception using errcode='22023',message='return departure must be after outbound arrival';end if;

  insert into pace_v2.service_return_designs(service_id,reverse_route_id,return_local_time,return_duration_minutes) values(v_service.id,v_return_route.id,p_return_local_time,p_return_duration_minutes)
  on conflict(service_id) do update set reverse_route_id=excluded.reverse_route_id,return_local_time=excluded.return_local_time,return_duration_minutes=excluded.return_duration_minutes,updated_at=now()
  where pace_v2.service_return_designs.reverse_route_id is distinct from excluded.reverse_route_id
     or pace_v2.service_return_designs.return_local_time is distinct from excluded.return_local_time
     or pace_v2.service_return_designs.return_duration_minutes is distinct from excluded.return_duration_minutes
  returning * into v_design;
  if v_design.id is null then select * into v_design from pace_v2.service_return_designs where service_id=v_service.id;end if;
  journey_pair_id:=null;
  outbound_departure_id:=null;
  return_departure_id:=null;
  for v_outbound_id in
    select d.id
    from pace_v2.departures d
    where d.service_id=v_service.id
      and pace_v2.is_qualified_service_departure(v_service.id,d.id,p_outbound_local_time)
    order by d.scheduled_departure_ts,d.id
  loop
    v_return_id:=pace_v2.materialize_service_return_leg(v_outbound_id);
    if outbound_departure_id is null and v_return_id is not null then
      select * into v_outbound from pace_v2.departures where id=v_outbound_id;
      select departure.journey_pair_id into v_pair_id
      from pace_v2.departures departure where departure.id=v_outbound_id;
      journey_pair_id:=v_pair_id;
      outbound_departure_id:=v_outbound_id;
      return_departure_id:=v_return_id;
    end if;
  end loop;
  updated_at:=v_design.updated_at;
  return next;
end $$;

create function public.v2_admin_save_paired_journey_design(
  p_service_id uuid,p_outbound_local_time time,p_return_enabled boolean,p_return_local_time time default null,p_return_duration_minutes integer default null,p_reverse_route_id uuid default null
) returns table(journey_pair_id uuid,outbound_departure_id uuid,return_departure_id uuid,updated_at timestamptz)
language sql security definer set search_path='' as $$ select * from pace_v2.admin_save_paired_journey_design(p_service_id,p_outbound_local_time,p_return_enabled,p_return_local_time,p_return_duration_minutes,p_reverse_route_id) $$;

drop function if exists public.v2_admin_paired_journey_design(uuid);
create function public.v2_admin_paired_journey_design(p_service_id uuid)
returns table(outbound_local_time time,return_enabled boolean,return_local_time time,return_duration_minutes integer,reverse_route_id uuid,eligible_return_routes jsonb)
language sql security definer set search_path='' as $$
  select s.departure_time,d.id is not null,d.return_local_time,d.return_duration_minutes,d.reverse_route_id,eligible.routes
  from pace_v2.services s left join pace_v2.service_return_designs d on d.service_id=s.id
  left join lateral(
    select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'route_name',coalesce(r.route_name,r.name)) order by coalesce(r.route_name,r.name)),'[]'::jsonb) routes
    from pace_v2.route_return_mappings m join pace_v2.routes r on r.id=m.return_route_id and r.is_active
    where m.outbound_route_id=s.route_id
  ) eligible on true
  where s.id=p_service_id and pace_v2.is_site_admin()
$$;
revoke all on function pace_v2.admin_save_paired_journey_design(uuid,time,boolean,time,integer,uuid) from public,anon,authenticated;
revoke all on function pace_v2.is_qualified_service_departure(uuid,uuid,time) from public,anon,authenticated;
revoke all on function pace_v2.next_service_operating_date(uuid,time) from public,anon,authenticated;
revoke all on function pace_v2.materialize_service_return_leg(uuid) from public,anon,authenticated;
revoke all on function public.v2_admin_save_paired_journey_design(uuid,time,boolean,time,integer,uuid) from public,anon;
revoke all on function public.v2_admin_paired_journey_design(uuid) from public,anon;
grant execute on function public.v2_admin_save_paired_journey_design(uuid,time,boolean,time,integer,uuid),public.v2_admin_paired_journey_design(uuid) to authenticated;

-- Quote is the public checkout boundary. It must reject a paired return
-- before the allocation/price engine is consulted.
create or replace function public.v2_public_quote(p_departure_id uuid,p_party_size integer)
returns table(result_status text,departure_id uuid,route_id uuid,route_name text,pickup_name text,destination_name text,scheduled_departure_ts timestamptz,trip_timezone text,vehicle_consideration_id uuid,vehicle_id uuid,vehicle_name text,operator_id uuid,operator_name text,allocation_stage text,net_unit_price_cents integer,tax_cents integer,fee_cents integer,all_in_unit_price_cents integer,all_in_total_cents integer,currency text,discount_applied boolean,discount_bps integer,quality_score numeric,max_party_size integer,remaining_seats_total integer,quote_expires_at timestamptz)
language plpgsql security definer set search_path=public,pace_v2 as $$
declare offer record;dep record;tf record;v_tax integer:=0;v_fee integer:=0;v_tax_cents integer;v_fee_cents integer;v_allin integer;v_max integer;v_total integer;v_expiry timestamptz;
begin
 if p_party_size is null or p_party_size<1 or p_party_size>50 then raise exception 'Party size must be between 1 and 50';end if;
 select d.id,d.route_id,r.route_name,r.country_id,p.name pickup_name,dst.name destination_name,d.scheduled_departure_ts,d.trip_timezone,d.t24_ts into dep
 from pace_v2.departures d join pace_v2.routes r on r.id=d.route_id and r.is_active join pace_v2.countries c on c.id=r.country_id and c.active and c.customer_availability_paused is not true join pace_v2.pickup_points p on p.id=r.pickup_id and p.active join pace_v2.destinations dst on dst.id=r.destination_id and dst.active and dst.published_at is not null
 where d.id=p_departure_id and d.is_commercial and d.scheduled_departure_ts>now() and d.t24_ts>now() and d.status in('scheduled','selling','at_risk','under_consideration');
 if dep.id is null then raise exception 'Journey is not currently available for booking';end if;
 v_expiry:=least(dep.t24_ts,now()+interval '15 minutes');select * into offer from pace_v2.get_live_party_offer(p_departure_id,p_party_size);
 select coalesce(max(greatest(vc.max_seats-vc.assigned_seats-pace_v2.pending_reserved_seats(vc.departure_id,vc.vehicle_id),0)),0),coalesce(sum(greatest(vc.max_seats-vc.assigned_seats-pace_v2.pending_reserved_seats(vc.departure_id,vc.vehicle_id),0)),0) into v_max,v_total from pace_v2.vehicle_considerations vc where vc.departure_id=p_departure_id and vc.status not in('withdrawn','discarded_t72','under_consideration','confirmed','replaced','cancelled');
 if offer.result_status<>'offer' then return query select offer.result_status,dep.id,dep.route_id,dep.route_name,dep.pickup_name,dep.destination_name,dep.scheduled_departure_ts,dep.trip_timezone,offer.vehicle_consideration_id,offer.vehicle_id,offer.vehicle_name,offer.operator_id,offer.operator_name,offer.allocation_stage,coalesce(offer.offered_price_cents,0),0,0,0,0,'USD',coalesce(offer.discount_applied,false),coalesce(offer.discount_bps,0),offer.quality_score,v_max,v_total,v_expiry;return;end if;
 select ctf.tax_bps,ctf.customer_fee_bps into tf from pace_v2.country_tax_fees ctf where ctf.country_id=dep.country_id and ctf.effective_from<=now() and (ctf.effective_to is null or ctf.effective_to>now()) order by ctf.effective_from desc limit 1;
 v_tax:=coalesce(tf.tax_bps,0);v_fee:=coalesce(tf.customer_fee_bps,0);v_tax_cents:=round(offer.offered_price_cents*v_tax/10000.0);v_fee_cents:=round((offer.offered_price_cents+v_tax_cents)*v_fee/10000.0);v_allin:=offer.offered_price_cents+v_tax_cents+v_fee_cents;
 return query select 'offer',dep.id,dep.route_id,dep.route_name,dep.pickup_name,dep.destination_name,dep.scheduled_departure_ts,dep.trip_timezone,offer.vehicle_consideration_id,offer.vehicle_id,offer.vehicle_name,offer.operator_id,offer.operator_name,offer.allocation_stage,offer.offered_price_cents,v_tax_cents,v_fee_cents,v_allin,v_allin*p_party_size,'USD',offer.discount_applied,offer.discount_bps,offer.quality_score,v_max,v_total,v_expiry;
end $$;
grant execute on function public.v2_public_quote(uuid,integer) to anon,authenticated;

-- A paired duty consumes one captain and vehicle continuously from the
-- commercial outbound departure until the scheduled arrival of its return.
-- Keeping this identity in one private helper prevents inventory, automatic
-- captain selection and deferred allocation validation from drifting apart.
create or replace function pace_v2.captain_duty_resource_window(p_departure_id uuid)
returns table(
  outbound_departure_id uuid,
  final_departure_id uuid,
  scheduled_start_ts timestamptz,
  scheduled_end_ts timestamptz,
  outbound_route_id uuid,
  final_route_id uuid,
  final_scheduled_departure_ts timestamptz
)
language sql stable security definer set search_path='' as $$
  select
    outbound.id,
    coalesce(pair.return_departure_id,outbound.id),
    outbound.scheduled_departure_ts,
    coalesce(return_leg.scheduled_arrival_ts,outbound.scheduled_arrival_ts,
      outbound.scheduled_departure_ts+interval '8 hours'),
    outbound.route_id,
    coalesce(return_leg.route_id,outbound.route_id),
    coalesce(return_leg.scheduled_departure_ts,outbound.scheduled_departure_ts)
  from pace_v2.departures requested
  left join pace_v2.journey_pairs pair on pair.id=requested.journey_pair_id
  join pace_v2.departures outbound
    on outbound.id=coalesce(pair.outbound_departure_id,requested.id)
  left join pace_v2.departures return_leg
    on return_leg.id=pair.return_departure_id
  where requested.id=p_departure_id
$$;

create or replace function pace_v2.get_eligible_vehicle_offers(p_departure_id uuid)
returns table(
  departure_id uuid,
  route_id uuid,
  vehicle_route_offer_id uuid,
  vehicle_id uuid,
  operator_id uuid,
  vehicle_type_id uuid,
  normal_min_seats integer,
  max_seats integer,
  min_revenue_cents integer,
  min_value_threshold_ratio numeric,
  normal_base_seat_price_cents integer,
  quality_score numeric,
  effective_commission_bps integer,
  effective_commission_source text
)
language sql stable security definer set search_path='' as $eligibility$
  with candidate as (
    select departure.id as departure_id,departure.route_id,route.country_id,
      resource.scheduled_start_ts,resource.scheduled_end_ts,
      offer.id as vehicle_route_offer_id,vehicle.id as vehicle_id,
      vehicle.operator_id,vehicle.vehicle_type_id,offer.min_seats,
      offer.max_seats,offer.min_revenue_cents,offer.min_value_threshold_ratio,
      ceil(offer.min_revenue_cents::numeric/offer.min_seats)::integer as base_seat_price,
      fleet_operator.quality_score
    from pace_v2.departures departure
    join pace_v2.routes route on route.id=departure.route_id
    cross join lateral pace_v2.captain_duty_resource_window(departure.id) resource
    join pace_v2.vehicle_route_offers offer
      on offer.service_id=departure.service_id and offer.active
     and offer.effective_from<=resource.scheduled_start_ts
     and (offer.effective_to is null or offer.effective_to>resource.scheduled_start_ts)
    join pace_v2.vehicles vehicle on vehicle.id=offer.vehicle_id and vehicle.active
    join pace_v2.operators fleet_operator
      on fleet_operator.id=vehicle.operator_id and fleet_operator.active
    join pace_v2.operator_vehicle_types operator_type
      on operator_type.operator_id=vehicle.operator_id
     and operator_type.vehicle_type_id=vehicle.vehicle_type_id
     and operator_type.status='approved'
    join pace_v2.route_vehicle_types outbound_route_eligibility
      on outbound_route_eligibility.route_id=resource.outbound_route_id
     and outbound_route_eligibility.vehicle_type_id=vehicle.vehicle_type_id
     and outbound_route_eligibility.active
     and outbound_route_eligibility.effective_from<=resource.scheduled_start_ts
     and (outbound_route_eligibility.effective_to is null
       or outbound_route_eligibility.effective_to>resource.scheduled_start_ts)
    join pace_v2.route_vehicle_types return_route_eligibility
      on return_route_eligibility.route_id=resource.final_route_id
     and return_route_eligibility.vehicle_type_id=vehicle.vehicle_type_id
     and return_route_eligibility.active
     and return_route_eligibility.effective_from<=resource.final_scheduled_departure_ts
     and (return_route_eligibility.effective_to is null
       or return_route_eligibility.effective_to>resource.final_scheduled_departure_ts)
    where departure.id=p_departure_id
      and departure.status not in('cancelled','completed')
      and not exists(
        select 1 from pace_v2.vehicle_availability_exceptions availability
        where availability.vehicle_id=vehicle.id
          and availability.start_ts<resource.scheduled_end_ts
          and availability.end_ts>resource.scheduled_start_ts
      )
      and not exists(
        select 1
        from pace_v2.confirmed_allocations other_allocation
        cross join lateral pace_v2.captain_duty_resource_window(other_allocation.departure_id) other_resource
        where other_allocation.vehicle_id=vehicle.id
          and other_allocation.status='confirmed'
          and other_allocation.departure_id<>resource.outbound_departure_id
          and other_resource.scheduled_start_ts<resource.scheduled_end_ts
          and other_resource.scheduled_end_ts>resource.scheduled_start_ts
      )
  )
  select candidate.departure_id,candidate.route_id,candidate.vehicle_route_offer_id,
    candidate.vehicle_id,candidate.operator_id,candidate.vehicle_type_id,
    candidate.min_seats,candidate.max_seats,candidate.min_revenue_cents,
    candidate.min_value_threshold_ratio,candidate.base_seat_price,
    candidate.quality_score,commission.commission_bps,commission.commission_source
  from candidate
  left join lateral pace_v2.get_effective_commission(
    candidate.operator_id,candidate.country_id,candidate.scheduled_start_ts
  ) commission on true
$eligibility$;

create or replace function pace_v2.pick_default_captain(p_confirmed_allocation_id uuid)
returns table(captain_id uuid,priority integer)
language sql stable security definer set search_path='' as $$
  with target as (
    select allocation.id as confirmed_allocation_id,allocation.vehicle_id,
      allocation.operator_id,vehicle.vehicle_type_id,
      resource.scheduled_start_ts,resource.scheduled_end_ts,
      route_offer.preferred_captain_id as route_captain_id
    from pace_v2.confirmed_allocations allocation
    join pace_v2.vehicles vehicle on vehicle.id=allocation.vehicle_id
    cross join lateral pace_v2.captain_duty_resource_window(allocation.departure_id) resource
    left join pace_v2.vehicle_considerations consideration
      on consideration.id=allocation.consideration_id
    left join pace_v2.vehicle_route_offers route_offer
      on route_offer.id=consideration.vehicle_route_offer_id
    where allocation.id=p_confirmed_allocation_id
  ), preferences as (
    select target.route_captain_id as captain_id,0 as priority
    from target where target.route_captain_id is not null
    union all
    select preference.captain_id,100+preference.priority
    from target
    join pace_v2.vehicle_captain_preferences preference
      on preference.vehicle_id=target.vehicle_id
     and preference.operator_id=target.operator_id and preference.active
    union all
    select captain.id,10000
    from target join pace_v2.captains captain
      on captain.operator_id=target.operator_id and captain.active
  ), ranked as (
    select preferences.captain_id,min(preferences.priority)::integer as priority
    from preferences group by preferences.captain_id
  )
  select ranked.captain_id,ranked.priority
  from ranked
  join target on true
  join pace_v2.captains captain
    on captain.id=ranked.captain_id and captain.operator_id=target.operator_id and captain.active
  join pace_v2.captain_vehicle_types eligibility
    on eligibility.captain_id=captain.id
   and eligibility.vehicle_type_id=target.vehicle_type_id and eligibility.active
  where not exists(
    select 1
    from pace_v2.captain_assignments other_assignment
    join pace_v2.confirmed_allocations other_allocation
      on other_allocation.id=other_assignment.confirmed_allocation_id
    cross join lateral pace_v2.captain_duty_resource_window(other_allocation.departure_id) other_resource
    where other_assignment.captain_id=captain.id and other_assignment.active
      and other_allocation.status='confirmed'
      and other_allocation.id<>p_confirmed_allocation_id
      and other_resource.scheduled_start_ts<target.scheduled_end_ts
      and other_resource.scheduled_end_ts>target.scheduled_start_ts
  )
  order by ranked.priority,ranked.captain_id
  limit 1
$$;

create or replace function pace_v2.assert_confirmed_allocation_has_eligible_captain(p_confirmed_allocation_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare
  v_allocation pace_v2.confirmed_allocations%rowtype;
  v_vehicle pace_v2.vehicles%rowtype;
  v_resource record;
  v_resource_key text;
begin
  -- This first lock also ensures every subsequent statement takes its
  -- READ COMMITTED snapshot after any prior allocator has committed.
  perform pg_advisory_xact_lock(
    hashtextextended('confirmed-allocation-resource:global',0)
  );
  select * into v_allocation from pace_v2.confirmed_allocations
  where id=p_confirmed_allocation_id;
  if v_allocation.id is null or v_allocation.status<>'confirmed' then return; end if;
  select * into v_vehicle from pace_v2.vehicles where id=v_allocation.vehicle_id;
  select * into v_resource
  from pace_v2.captain_duty_resource_window(v_allocation.departure_id);

  -- Deferred constraints alone do not prevent write skew. Every transaction
  -- touching an allocation takes the same transaction advisory locks for its
  -- vehicle and active captains, in a single global lexical order. A waiter
  -- therefore observes the first committer before validating overlap.
  for v_resource_key in
    select resource_key
    from (
      select 'confirmed-allocation-resource:vehicle:'||v_allocation.vehicle_id::text as resource_key
      union
      select 'confirmed-allocation-resource:captain:'||assignment.captain_id::text
      from pace_v2.captain_assignments assignment
      where assignment.confirmed_allocation_id=v_allocation.id and assignment.active
    ) locked_resources
    order by resource_key
  loop
    perform pg_advisory_xact_lock(hashtextextended(v_resource_key,0));
  end loop;

  if not coalesce(v_vehicle.active,false)
     or not exists(
       select 1
       from pace_v2.captain_assignments assignment
       join pace_v2.captains captain
         on captain.id=assignment.captain_id and captain.active
        and captain.operator_id=v_allocation.operator_id
       join pace_v2.captain_vehicle_types eligibility
         on eligibility.captain_id=captain.id and eligibility.active
        and eligibility.vehicle_type_id=v_vehicle.vehicle_type_id
       where assignment.confirmed_allocation_id=v_allocation.id and assignment.active
     ) then
    raise exception 'confirmed allocation requires an active eligible assigned captain';
  end if;

  if not exists(
       select 1 from pace_v2.route_vehicle_types outbound_route_eligibility
       where outbound_route_eligibility.route_id=v_resource.outbound_route_id
         and outbound_route_eligibility.vehicle_type_id=v_vehicle.vehicle_type_id
         and outbound_route_eligibility.active
         and outbound_route_eligibility.effective_from<=v_resource.scheduled_start_ts
         and (outbound_route_eligibility.effective_to is null
           or outbound_route_eligibility.effective_to>v_resource.scheduled_start_ts)
     )
     or not exists(
       select 1 from pace_v2.route_vehicle_types return_route_eligibility
       where return_route_eligibility.route_id=v_resource.final_route_id
         and return_route_eligibility.vehicle_type_id=v_vehicle.vehicle_type_id
         and return_route_eligibility.active
         and return_route_eligibility.effective_from<=v_resource.final_scheduled_departure_ts
         and (return_route_eligibility.effective_to is null
           or return_route_eligibility.effective_to>v_resource.final_scheduled_departure_ts)
     )
     or exists(
       select 1 from pace_v2.vehicle_availability_exceptions availability
       where availability.vehicle_id=v_vehicle.id
         and availability.start_ts<v_resource.scheduled_end_ts
         and availability.end_ts>v_resource.scheduled_start_ts
     )
     or exists(
       select 1
       from pace_v2.confirmed_allocations other_allocation
       cross join lateral pace_v2.captain_duty_resource_window(other_allocation.departure_id) other_resource
       where other_allocation.vehicle_id=v_vehicle.id
         and other_allocation.status='confirmed'
         and other_allocation.id<>v_allocation.id
         and other_resource.scheduled_start_ts<v_resource.scheduled_end_ts
         and other_resource.scheduled_end_ts>v_resource.scheduled_start_ts
     )
     or exists(
       select 1
       from pace_v2.captain_assignments assignment
       join pace_v2.captain_assignments other_assignment
         on other_assignment.captain_id=assignment.captain_id and other_assignment.active
       join pace_v2.confirmed_allocations other_allocation
         on other_allocation.id=other_assignment.confirmed_allocation_id
        and other_allocation.status='confirmed'
       cross join lateral pace_v2.captain_duty_resource_window(other_allocation.departure_id) other_resource
       where assignment.confirmed_allocation_id=v_allocation.id and assignment.active
         and other_allocation.id<>v_allocation.id
         and other_resource.scheduled_start_ts<v_resource.scheduled_end_ts
         and other_resource.scheduled_end_ts>v_resource.scheduled_start_ts
     ) then
    raise exception 'confirmed allocation resource window conflicts';
  end if;
end $$;

create or replace function pace_v2.validate_vehicle_availability_change()
returns trigger language plpgsql security definer set search_path='' as $$
declare
  v_vehicle_id uuid;
  v_allocation_id uuid;
begin
  for v_vehicle_id in
    select distinct affected.vehicle_id
    from unnest(case
      when tg_op='INSERT' then array[new.vehicle_id]
      when tg_op='DELETE' then array[old.vehicle_id]
      else array[old.vehicle_id,new.vehicle_id]
    end) affected(vehicle_id)
    where affected.vehicle_id is not null
    order by affected.vehicle_id
  loop
    for v_allocation_id in
      select allocation.id
      from pace_v2.confirmed_allocations allocation
      where allocation.vehicle_id=v_vehicle_id and allocation.status='confirmed'
      order by allocation.id
    loop
      perform pace_v2.assert_confirmed_allocation_has_eligible_captain(v_allocation_id);
    end loop;
  end loop;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

create or replace function pace_v2.validate_route_vehicle_type_change()
returns trigger language plpgsql security definer set search_path='' as $$
declare
  v_route_ids uuid[];
  v_vehicle_type_ids uuid[];
  v_allocation_id uuid;
begin
  if tg_op='INSERT' then
    v_route_ids:=array[new.route_id];
    v_vehicle_type_ids:=array[new.vehicle_type_id];
  elsif tg_op='DELETE' then
    v_route_ids:=array[old.route_id];
    v_vehicle_type_ids:=array[old.vehicle_type_id];
  else
    v_route_ids:=array[old.route_id,new.route_id];
    v_vehicle_type_ids:=array[old.vehicle_type_id,new.vehicle_type_id];
  end if;

  for v_allocation_id in
    select distinct allocation.id
    from pace_v2.confirmed_allocations allocation
    join pace_v2.vehicles vehicle on vehicle.id=allocation.vehicle_id
    cross join lateral pace_v2.captain_duty_resource_window(allocation.departure_id) resource
    where allocation.status='confirmed'
      and vehicle.vehicle_type_id=any(v_vehicle_type_ids)
      and (resource.outbound_route_id=any(v_route_ids)
        or resource.final_route_id=any(v_route_ids))
    order by allocation.id
  loop
    perform pace_v2.assert_confirmed_allocation_has_eligible_captain(v_allocation_id);
  end loop;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

alter function pace_v2.validate_vehicle_availability_change() owner to postgres;
alter function pace_v2.validate_route_vehicle_type_change() owner to postgres;

create constraint trigger vehicle_availability_preserves_allocated_resources
after insert or update or delete on pace_v2.vehicle_availability_exceptions
deferrable initially deferred
for each row execute function pace_v2.validate_vehicle_availability_change();

create constraint trigger route_vehicle_type_preserves_allocated_resources
after insert or update or delete on pace_v2.route_vehicle_types
deferrable initially deferred
for each row execute function pace_v2.validate_route_vehicle_type_change();

-- Do not grandfather pre-migration conflicts. The same serialized invariant
-- used for future writes validates the complete confirmed set in stable order;
-- operators must remediate any reported vehicle/captain/route availability
-- conflict in preview before this migration can be applied.
do $confirmed_allocation_resource_preflight$
declare
  v_allocation_id uuid;
begin
  for v_allocation_id in
    select allocation.id
    from pace_v2.confirmed_allocations allocation
    where allocation.status='confirmed'
    order by allocation.id
  loop
    perform pace_v2.assert_confirmed_allocation_has_eligible_captain(v_allocation_id);
  end loop;
end
$confirmed_allocation_resource_preflight$;

revoke all on function pace_v2.captain_duty_resource_window(uuid),
  pace_v2.get_eligible_vehicle_offers(uuid),
  pace_v2.pick_default_captain(uuid),
  pace_v2.assert_confirmed_allocation_has_eligible_captain(uuid),
  pace_v2.validate_vehicle_availability_change(),
  pace_v2.validate_route_vehicle_type_change()
from public,anon,authenticated;

create or replace function public.v2_system_partner_shuttle_catalog(p_api_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_partner pace_v2.api_partners%rowtype;v_recent_requests integer;v_tiles jsonb;
begin
 if nullif(trim(coalesce(p_api_key,'')),'') is null then return jsonb_build_object('authorized',false);end if;
 select * into v_partner from pace_v2.api_partners where api_key_hash=encode(extensions.digest(p_api_key,'sha256'),'hex') and active limit 1 for update;
 if v_partner.id is null then return jsonb_build_object('authorized',false);end if;
 select count(*) into v_recent_requests from pace_v2.partner_api_requests where partner_id=v_partner.id and requested_at>=now()-interval '1 minute';
 if v_recent_requests>=v_partner.rate_limit_per_minute then return jsonb_build_object('authorized',true,'rate_limited',true);end if;
 insert into pace_v2.partner_api_requests(partner_id) values(v_partner.id);update pace_v2.api_partners set last_used_at=now(),updated_at=now() where id=v_partner.id;
 with viable as(
  select distinct on(d.route_id) d.route_id,d.scheduled_departure_ts,eligible.vehicle_type_id
  from pace_v2.departures d
  join pace_v2.routes viable_route on viable_route.id=d.route_id and viable_route.is_active
  join pace_v2.countries viable_country on viable_country.id=viable_route.country_id and viable_country.active and viable_country.customer_availability_paused is not true
  cross join lateral pace_v2.get_eligible_vehicle_offers(d.id) eligible
  where d.is_commercial and d.scheduled_departure_ts>now() and d.status in('scheduled','selling','at_risk','under_consideration')
  order by d.route_id,d.scheduled_departure_ts,eligible.vehicle_type_id
 ) select coalesce(jsonb_agg(tile order by tile->>'route_name'),'[]'::jsonb) into v_tiles from(
  select jsonb_build_object('route_id',r.id,'country',c.name,'vehicle_type',vt.name,'route_name',r.route_name,'pickup',jsonb_build_object('id',p.id,'name',p.name,'image_url',p.picture_url),'destination',jsonb_build_object('id',dst.id,'name',dst.name,'image_url',dst.picture_url),'schedule',nullif(trim(coalesce(r.frequency,'')),'')) tile
  from viable join pace_v2.routes r on r.id=viable.route_id and r.is_active join pace_v2.countries c on c.id=r.country_id and c.active and c.customer_availability_paused is not true join pace_v2.pickup_points p on p.id=r.pickup_id and p.active join pace_v2.destinations dst on dst.id=r.destination_id and dst.active and dst.published_at is not null join pace_v2.vehicle_types vt on vt.id=viable.vehicle_type_id and vt.active where r.country_id=v_partner.country_id
 ) catalogue;
 return jsonb_build_object('authorized',true,'partner',jsonb_build_object('id',v_partner.id,'name',v_partner.name),'country_id',v_partner.country_id,'tiles',v_tiles);
end $$;
revoke all on function public.v2_system_partner_shuttle_catalog(text) from public,anon,authenticated;
grant execute on function public.v2_system_partner_shuttle_catalog(text) to service_role;

create or replace view public.v2_public_departures as
with eligible as(
 select d.id departure_id,eligible.vehicle_type_id
 from pace_v2.departures d
 join pace_v2.routes r on r.id=d.route_id and r.is_active
 join pace_v2.countries c on c.id=r.country_id and c.active and c.customer_availability_paused is not true
 join pace_v2.destinations dst on dst.id=r.destination_id and dst.active and dst.published_at is not null
 cross join lateral pace_v2.get_eligible_vehicle_offers(d.id) eligible
 where d.is_commercial and d.scheduled_departure_ts>now() and d.status in('scheduled','selling','at_risk','under_consideration')
 group by d.id,eligible.vehicle_type_id
), types as(
 select e.departure_id,jsonb_agg(jsonb_build_object('id',vt.id,'name',vt.name,'picture_url',vt.picture_url) order by vt.name) vehicle_types
 from eligible e join pace_v2.vehicle_types vt on vt.id=e.vehicle_type_id and vt.active group by e.departure_id
)
select d.id departure_id,d.route_id,r.route_name,r.country_id,r.pickup_id,r.destination_id,r.approx_duration_mins,r.trip_timezone,r.picture_url route_picture_url,r.display_description,d.scheduled_departure_ts,d.scheduled_arrival_ts,d.local_departure_date,d.status,d.t72_ts,d.t24_ts,p.name pickup_name,p.picture_url pickup_picture_url,p.description pickup_description,dst.name destination_name,dst.picture_url destination_picture_url,dst.description destination_description,dst.wet_or_dry,t.vehicle_types
from types t join pace_v2.departures d on d.id=t.departure_id join pace_v2.routes r on r.id=d.route_id join pace_v2.pickup_points p on p.id=r.pickup_id and p.active join pace_v2.destinations dst on dst.id=r.destination_id and dst.active and dst.published_at is not null;

-- Legacy completion transitions an allocation from confirmed to completed
-- before the asynchronous feedback scheduler runs. Keep completed journeys
-- eligible without changing any customer, timing, captain or email predicate.
create or replace function public.v2_system_schedule_feedback_requests(p_as_of timestamptz,p_limit integer default 100)
returns integer language plpgsql security definer set search_path=public,pace_v2,auth as $schedule$
declare v_row record; v_due_at timestamptz; v_queued integer:=0; v_feedback_url text;
begin
  if p_as_of is null then raise exception 'as-of timestamp required'; end if;
  update pace_v2.operational_alerts oa
  set resolved_at=now(),resolution_note='Country timezone corrected; feedback request will be queued when due'
  from pace_v2.confirmed_allocations ca
  join pace_v2.departures d on d.id=ca.departure_id
  join pace_v2.routes r on r.id=d.route_id
  join pace_v2.countries c on c.id=r.country_id
  join pg_timezone_names tz on tz.name=c.timezone
  where oa.exception_type='feedback_timezone_invalid' and oa.resolved_at is null and oa.confirmed_allocation_id=ca.id;
  insert into pace_v2.operational_alerts(exception_key,exception_type,severity,confirmed_allocation_id,booking_id,departure_id,details)
  select distinct on (b.id)
    'feedback_timezone_invalid:'||b.id::text,'feedback_timezone_invalid','high',ca.id,b.id,d.id,
    jsonb_build_object('country_name',c.name,'timezone',c.timezone,'as_of',p_as_of)
  from pace_v2.bookings b
  join pace_v2.booking_allocations ba on ba.booking_id=b.id
  join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status in('confirmed','completed')
  join pace_v2.departures d on d.id=ca.departure_id
  join pace_v2.routes r on r.id=d.route_id
  join pace_v2.countries c on c.id=r.country_id
  left join pg_timezone_names tz on tz.name=c.timezone
  join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id
  join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id)
  where tz.name is null and d.actual_arrival_ts is not null and d.actual_arrival_ts<=p_as_of
    and pace_v2.is_active_paid_journey_booking(b.id,null)
    and not exists(select 1 from pace_v2.customer_feedback cf where cf.booking_id=b.id)
    and pace_v2.is_valid_customer_notification_email(u.email)
    and nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),'') is not null
    and (select count(*) from pace_v2.captain_assignments a2 where a2.confirmed_allocation_id=ca.id and a2.active)=1
    and not exists(select 1 from pace_v2.notifications n where n.booking_id=b.id and n.template_code='post_journey_feedback')
  order by b.id,ca.id,a.id
  on conflict (exception_key) where resolved_at is null do update
    set severity='high',confirmed_allocation_id=excluded.confirmed_allocation_id,departure_id=excluded.departure_id,details=excluded.details,detected_at=excluded.detected_at;
  for v_row in
    select distinct on (b.id) b.id booking_id,ca.id confirmed_allocation_id,d.id departure_id,d.actual_arrival_ts,c.name country_name,c.timezone,
      pp.name pickup_name,dst.name destination_name,nullif(trim(u.email),'') to_email,
      split_part(nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),''),' ',1) first_name
    from pace_v2.bookings b
    join pace_v2.booking_allocations ba on ba.booking_id=b.id
    join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status in('confirmed','completed')
    join pace_v2.departures d on d.id=ca.departure_id
    join pace_v2.routes r on r.id=d.route_id
    join pace_v2.countries c on c.id=r.country_id
    join pg_timezone_names tz on tz.name=c.timezone
    join pace_v2.pickup_points pp on pp.id=r.pickup_id
    join pace_v2.destinations dst on dst.id=r.destination_id
    join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
    join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id
    join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id)
    where d.actual_arrival_ts is not null and d.actual_arrival_ts<=p_as_of
      and case when tz.name is not null then pace_v2.feedback_due_at(d.actual_arrival_ts,c.timezone)<=p_as_of else false end
      and pace_v2.is_active_paid_journey_booking(b.id,null)
      and not exists(select 1 from pace_v2.customer_feedback cf where cf.booking_id=b.id)
      and not exists(select 1 from pace_v2.notifications n where n.booking_id=b.id and n.template_code='post_journey_feedback')
      and pace_v2.is_valid_customer_notification_email(u.email)
      and nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),'') is not null
      and (select count(*) from pace_v2.captain_assignments a2 where a2.confirmed_allocation_id=ca.id and a2.active)=1
    order by b.id,ca.id,a.id
    limit least(greatest(coalesce(p_limit,0),0),500)
  loop
    v_due_at:=pace_v2.feedback_due_at(v_row.actual_arrival_ts,v_row.timezone);
    v_feedback_url:='https://www.paceshuttles.com/customer?booking='||v_row.booking_id::text||'&feedback=1';
    insert into pace_v2.notifications(booking_id,departure_id,to_email,template_code,subject,body,status,scheduled_at,metadata)
    values(v_row.booking_id,v_row.departure_id,v_row.to_email,'post_journey_feedback',
      'Thank you for travelling with Pace Shuttles – one more thing…',
      'Hi '||v_row.first_name||E',\n\nThank you for travelling with Pace Shuttles. We hope you had a wonderful journey in '||v_row.country_name||' from '||v_row.pickup_name||' to '||v_row.destination_name||E'.\n\nWould you mind telling us what went well and what we could improve? It should take no more than two minutes.\n\nShare your feedback\n'||v_feedback_url||E'\n\nRegards,\nThe Pace Shuttles Team',
      'queued',v_due_at,jsonb_build_object('feedback_url',v_feedback_url,'feedback_due_at',v_due_at,'country_name',v_row.country_name,'pickup_name',v_row.pickup_name,'destination_name',v_row.destination_name))
    on conflict (booking_id,template_code) where template_code='post_journey_feedback' do nothing;
    if found then v_queued:=v_queued+1; end if;
  end loop;
  return v_queued;
end;
$schedule$;

-- Feedback scheduling and submission must agree on the allocation lifecycle.
-- Preserve the existing customer/payment/captain and de-duplication boundary
-- while accepting the completed allocation that produced the invitation.
create or replace function public.v2_customer_submit_feedback(p_booking_id uuid,p_booking_experience_rating integer,p_nps integer,p_operator_rating integer,p_captain_rating integer,p_pickup_rating integer,p_destination_rating integer,p_went_well text,p_could_improve text,p_testimonial_consent boolean)
returns uuid language plpgsql security definer set search_path=public,pace_v2,auth as $submit$
declare
  v_user_id uuid:=auth.uid(); v_row record; v_feedback_id uuid; v_operator_weight numeric; v_captain_weight numeric; v_decay integer;
  operator_rating_effect numeric; captain_rating_effect numeric; weighted_rating numeric; v_low_dimensions jsonb:='[]'::jsonb;
begin
  if v_user_id is null then raise exception 'authentication required'; end if;
  if not pace_v2.is_active_paid_journey_booking(p_booking_id,v_user_id) then raise exception 'eligible paid booking owned by the authenticated customer required'; end if;
  if p_booking_experience_rating is null or p_nps is null or p_operator_rating is null or p_captain_rating is null or p_pickup_rating is null or p_destination_rating is null then raise exception 'all ratings are required'; end if;
  if p_booking_experience_rating not between 1 and 5 or p_operator_rating not between 1 and 5 or p_captain_rating not between 1 and 5 or p_pickup_rating not between 1 and 5 or p_destination_rating not between 1 and 5 then raise exception 'ratings must be integers from 1 to 5'; end if;
  if p_nps not between 0 and 10 then raise exception 'NPS must be an integer from 0 to 10'; end if;
  if p_testimonial_consent is null then raise exception 'testimonial consent must be explicit'; end if;
  select ca.id confirmed_allocation_id,ca.operator_id,ca.vehicle_id,d.id departure_id,d.actual_arrival_ts,r.pickup_id,r.destination_id,a.captain_id
  into strict v_row
  from pace_v2.bookings b
  join pace_v2.booking_allocations ba on ba.booking_id=b.id
  join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status in('confirmed','completed')
  join pace_v2.departures d on d.id=ca.departure_id
  join pace_v2.routes r on r.id=d.route_id
  join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id
  where b.id=p_booking_id and d.actual_arrival_ts is not null and d.actual_arrival_ts<=now()
    and (select count(*) from pace_v2.captain_assignments a2 where a2.confirmed_allocation_id=ca.id and a2.active)=1;
  select operator_rating_weight,captain_rating_weight,evidence_decay_half_life_days into strict v_operator_weight,v_captain_weight,v_decay from pace_v2.quality_configuration where config_key='journey_feedback';
  operator_rating_effect:=(p_operator_rating-3)::numeric/2;
  captain_rating_effect:=(p_captain_rating-3)::numeric/2;
  weighted_rating := (operator_rating_effect * v_operator_weight) + (captain_rating_effect * v_captain_weight);

  insert into pace_v2.customer_feedback(booking_id,departure_id,confirmed_allocation_id,operator_id,vehicle_id,captain_id,pickup_id,destination_id,submitted_by,booking_experience_rating,pace_shuttles_nps_score,operator_rating,captain_rating,pickup_rating,destination_rating,went_well,could_improve,testimonial_consent,feedback_schema_version)
  values(p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,v_row.operator_id,v_row.vehicle_id,v_row.captain_id,v_row.pickup_id,v_row.destination_id,v_user_id,p_booking_experience_rating,p_nps,p_operator_rating,p_captain_rating,p_pickup_rating,p_destination_rating,nullif(trim(coalesce(p_went_well,'')),''),nullif(trim(coalesce(p_could_improve,'')),''),p_testimonial_consent,2)
  returning id into v_feedback_id;

  insert into pace_v2.platform_quality_history(feedback_id,booking_id,dimension,rating,rating_effect,operator_score_effect,occurred_at) values
    (v_feedback_id,p_booking_id,'booking_experience',p_booking_experience_rating,(p_booking_experience_rating-3)::numeric/2,0,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,'pace_shuttles_nps',p_nps,case when p_nps<=6 then -1 when p_nps<=8 then 0 else 1 end,0,v_row.actual_arrival_ts);
  insert into pace_v2.captain_quality_history(feedback_id,booking_id,departure_id,captain_id,rating,rating_effect,occurred_at) values(v_feedback_id,p_booking_id,v_row.departure_id,v_row.captain_id,p_captain_rating,captain_rating_effect,v_row.actual_arrival_ts);
  insert into pace_v2.pickup_quality_history(feedback_id,booking_id,departure_id,pickup_id,rating,rating_effect,occurred_at) values(v_feedback_id,p_booking_id,v_row.departure_id,v_row.pickup_id,p_pickup_rating,(p_pickup_rating-3)::numeric/2,v_row.actual_arrival_ts);
  insert into pace_v2.destination_quality_history(feedback_id,booking_id,departure_id,destination_id,rating,rating_effect,occurred_at) values(v_feedback_id,p_booking_id,v_row.departure_id,v_row.destination_id,p_destination_rating,(p_destination_rating-3)::numeric/2,v_row.actual_arrival_ts);

  insert into pace_v2.quality_evidence(feedback_id,booking_id,departure_id,confirmed_allocation_id,operator_id,vehicle_id,captain_id,pickup_id,destination_id,evidence_type,attribution,dimension,rating,rating_effect,operator_score_effect,evidence_weight,decay_half_life_days,occurred_at) values
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,null,null,null,null,null,'customer_feedback','pace_shuttles','booking_experience',p_booking_experience_rating,(p_booking_experience_rating-3)::numeric/2,0,1,v_decay,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,null,null,null,null,null,'customer_feedback','pace_shuttles','pace_shuttles_nps',p_nps,case when p_nps<=6 then -1 when p_nps<=8 then 0 else 1 end,0,1,v_decay,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,v_row.operator_id,v_row.vehicle_id,v_row.captain_id,null,null,'customer_feedback','operator','operator_journey',p_operator_rating,operator_rating_effect,weighted_rating,1,v_decay,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,v_row.operator_id,v_row.vehicle_id,v_row.captain_id,null,null,'customer_feedback','operator','captain',p_captain_rating,captain_rating_effect,0,1,v_decay,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,null,null,null,v_row.pickup_id,null,'customer_feedback','pace_shuttles','pickup',p_pickup_rating,(p_pickup_rating-3)::numeric/2,0,1,v_decay,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,null,null,null,null,v_row.destination_id,'customer_feedback','pace_shuttles','destination',p_destination_rating,(p_destination_rating-3)::numeric/2,0,1,v_decay,v_row.actual_arrival_ts);

  if p_booking_experience_rating<=2 then v_low_dimensions:=v_low_dimensions||'"booking_experience"'::jsonb; end if;
  if p_nps<=2 then v_low_dimensions:=v_low_dimensions||'"pace_shuttles_nps"'::jsonb; end if;
  if p_operator_rating<=2 then v_low_dimensions:=v_low_dimensions||'"operator_journey"'::jsonb; end if;
  if p_captain_rating<=2 then v_low_dimensions:=v_low_dimensions||'"captain"'::jsonb; end if;
  if p_pickup_rating<=2 then v_low_dimensions:=v_low_dimensions||'"pickup"'::jsonb; end if;
  if p_destination_rating<=2 then v_low_dimensions:=v_low_dimensions||'"destination"'::jsonb; end if;
  if jsonb_array_length(v_low_dimensions)>0 then
    insert into pace_v2.operational_alerts(exception_key,exception_type,severity,confirmed_allocation_id,booking_id,departure_id,details)
    values('journey_feedback_attribution_review:'||v_feedback_id::text,'journey_feedback_attribution_review','high',v_row.confirmed_allocation_id,p_booking_id,v_row.departure_id,jsonb_build_object('feedback_id',v_feedback_id,'low_dimensions',v_low_dimensions,'operator_score_effect',weighted_rating));
  end if;
  return v_feedback_id;
exception when no_data_found then raise exception 'completed confirmed journey with one captain required';
end;
$submit$;

revoke all on function public.v2_customer_submit_feedback(uuid,integer,integer,integer,integer,integer,integer,text,text,boolean) from public,anon,authenticated;
grant execute on function public.v2_customer_submit_feedback(uuid,integer,integer,integer,integer,integer,integer,text,text,boolean) to authenticated;

-- Per-leg evidence is deliberately separate from departures.actual_arrival_ts.
-- Existing messaging, feedback and settlement workflows treat the commercial
-- outbound departure's arrival as completion of the whole customer journey.
create table pace_v2.captain_leg_operations(
  confirmed_allocation_id uuid not null references pace_v2.confirmed_allocations(id),
  departure_id uuid not null references pace_v2.departures(id),
  captain_assignment_id uuid not null references pace_v2.captain_assignments(id),
  started_at timestamptz,
  started_by_user_id uuid references auth.users(id),
  ended_at timestamptz,
  ended_by_user_id uuid references auth.users(id),
  completion_state text check(completion_state in('normal','incident')),
  notes text,
  incident_summary text,
  legacy_start_authorized boolean not null default false,
  finalization_authorized boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (confirmed_allocation_id,departure_id),
  constraint captain_leg_operations_end_after_start_check
    check(ended_at is null or (started_at is not null and ended_at>=started_at)),
  constraint captain_leg_operations_start_actor_shape_check
    check(started_by_user_id is null or started_at is not null),
  constraint captain_leg_operations_end_actor_shape_check
    check(ended_by_user_id is null or ended_at is not null),
  constraint captain_leg_operations_completion_shape_check check(
    (ended_at is null and completion_state is null and notes is null and incident_summary is null)
    or
    (ended_at is not null and completion_state is not null
      and ((completion_state='normal' and incident_summary is null)
        or (completion_state='incident' and nullif(trim(incident_summary),'') is not null)))
  ),
  constraint captain_leg_operations_finalization_check
    check(not finalization_authorized or started_at is not null),
  constraint captain_leg_operations_legacy_start_check
    check(not legacy_start_authorized or (started_at is null and ended_at is null))
);
create index captain_leg_operations_assignment_idx
  on pace_v2.captain_leg_operations(captain_assignment_id);

create or replace function pace_v2.protect_captain_leg_operation_actors()
returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if old.started_at is not null and (
    new.started_at is distinct from old.started_at
    or new.started_by_user_id is distinct from old.started_by_user_id
  ) then
    raise exception 'captain leg start actor is immutable';
  end if;
  if old.ended_at is not null and (
    new.ended_at is distinct from old.ended_at
    or new.ended_by_user_id is distinct from old.ended_by_user_id
    or new.completion_state is distinct from old.completion_state
    or new.notes is distinct from old.notes
    or new.incident_summary is distinct from old.incident_summary
  ) then
    if new.ended_by_user_id is distinct from old.ended_by_user_id then
      raise exception 'captain leg end actor is immutable';
    end if;
    raise exception 'captain leg completion evidence is immutable';
  end if;
  return new;
end $$;

alter function pace_v2.protect_captain_leg_operation_actors() owner to postgres;
create trigger captain_leg_operation_actor_immutability
before update of started_at,started_by_user_id,ended_at,ended_by_user_id,completion_state,notes,incident_summary on pace_v2.captain_leg_operations
for each row execute function pace_v2.protect_captain_leg_operation_actors();

alter table pace_v2.captain_leg_operations enable row level security;
revoke all on table pace_v2.captain_leg_operations from public,anon,authenticated;
revoke all on function pace_v2.protect_captain_leg_operation_actors() from public,anon,authenticated;

-- One-way journeys retain their historical close calculation. A paired duty
-- stays messageable while Leg 2 is incomplete (including operational delay),
-- then retains the same four-hour post-completion window as legacy journeys.
create or replace function pace_v2.journey_message_closes_at(p_confirmed_allocation_id uuid)
returns timestamptz language sql stable security definer set search_path='' as $$
  select case
    when pair.id is null then
      coalesce(outbound.actual_arrival_ts+interval '4 hours',
        outbound.scheduled_arrival_ts+interval '12 hours')
    when return_leg.actual_arrival_ts is not null then
      return_leg.actual_arrival_ts+interval '4 hours'
    when final_operation.ended_at is not null then
      final_operation.ended_at+interval '4 hours'
    else greatest(return_leg.scheduled_arrival_ts+interval '12 hours',now()+interval '4 hours')
  end
  from pace_v2.confirmed_allocations allocation
  join pace_v2.departures outbound on outbound.id=allocation.departure_id
  left join pace_v2.journey_pairs pair on pair.outbound_departure_id=outbound.id
  left join pace_v2.departures return_leg on return_leg.id=pair.return_departure_id
  left join pace_v2.captain_leg_operations final_operation
    on final_operation.confirmed_allocation_id=allocation.id
   and final_operation.departure_id=pair.return_departure_id
  where allocation.id=p_confirmed_allocation_id
$$;
revoke all on function pace_v2.journey_message_closes_at(uuid) from public,anon,authenticated;

-- The legacy completion RPC is retained for one-way duties, but paired duties
-- may only cross its voyage/departure write boundary while the allocation's
-- final-leg state machine transaction holds this private authorization flag.
create or replace function pace_v2.prevent_paired_legacy_completion()
returns trigger
language plpgsql security definer set search_path='' as $$
declare
  v_departure_id uuid;
  v_allocation_id uuid;
  v_pair_id uuid;
  v_outbound_id uuid;
  v_return_id uuid;
  v_paired boolean:=false;
  v_authorized boolean:=false;
  v_start_authorized boolean:=false;
  v_start_changed boolean:=false;
  v_unpairing boolean:=false;
begin
  if tg_table_schema='pace_v2' and tg_table_name='departures' then
    v_departure_id:=new.id;
    v_pair_id:=coalesce(new.journey_pair_id,old.journey_pair_id);
    v_paired:=old.journey_pair_id is not null or new.journey_pair_id is not null
      or old.leg_number is not null or new.leg_number is not null;
    v_unpairing:=(old.journey_pair_id is not null and new.journey_pair_id is null)
      or (old.leg_number is not null and new.leg_number is null);

    select pair.outbound_departure_id,pair.return_departure_id
      into v_outbound_id,v_return_id
    from pace_v2.journey_pairs pair where pair.id=v_pair_id;

    -- Direct metadata clearing follows the same evidence prohibition as the
    -- admin removal RPC. This makes a prior unpair statement unable to turn a
    -- following voyage-log completion into an apparent one-way completion.
    if v_unpairing and (
      exists(select 1 from pace_v2.bookings booking
        where booking.departure_id=coalesce(v_outbound_id,v_departure_id))
      or exists(select 1 from pace_v2.booking_allocations booking_allocation
        join pace_v2.vehicle_considerations consideration
          on consideration.id=booking_allocation.vehicle_consideration_id
        where consideration.departure_id=coalesce(v_outbound_id,v_departure_id))
      or exists(select 1 from pace_v2.confirmed_allocations ca
        where ca.departure_id=coalesce(v_outbound_id,v_departure_id))
      or exists(select 1 from pace_v2.voyage_logs voyage
        join pace_v2.confirmed_allocations ca on ca.id=voyage.confirmed_allocation_id
        where ca.departure_id=coalesce(v_outbound_id,v_departure_id))
      or exists(select 1 from pace_v2.captain_leg_operations operation
        where operation.departure_id in(v_departure_id,v_outbound_id,v_return_id))
      or old.actual_departure_ts is not null or old.actual_arrival_ts is not null
      or new.actual_departure_ts is not null or new.actual_arrival_ts is not null
    ) then
      raise exception 'return journey cannot be removed after bookings, allocations or operation evidence exist';
    end if;

    v_start_changed:=new.actual_departure_ts is distinct from old.actual_departure_ts;
    if v_paired and v_start_changed then
      select exists(
        select 1
        from pace_v2.journey_pairs pair
        join pace_v2.confirmed_allocations ca on ca.departure_id=pair.outbound_departure_id
        join pace_v2.captain_leg_operations operation
          on operation.confirmed_allocation_id=ca.id
         and (
           (operation.departure_id=pair.outbound_departure_id and operation.legacy_start_authorized)
           or (operation.departure_id=pair.return_departure_id and operation.finalization_authorized)
         )
        where pair.id=v_pair_id
      ) into v_start_authorized;
      if not v_start_authorized then
        raise exception 'paired duty must be started with v2_captain_start_leg';
      end if;
    end if;

    if new.actual_arrival_ts is not distinct from old.actual_arrival_ts then
      return new;
    end if;
    if v_paired then
      select exists(
        select 1
        from pace_v2.journey_pairs pair
        join pace_v2.confirmed_allocations ca on ca.departure_id=pair.outbound_departure_id
        join pace_v2.captain_leg_operations operation
          on operation.confirmed_allocation_id=ca.id
         and operation.departure_id=pair.return_departure_id
         and operation.finalization_authorized
        where pair.id=v_pair_id
      ) into v_authorized;
    end if;
  elsif tg_table_schema='pace_v2' and tg_table_name='voyage_logs' then
    v_allocation_id:=new.confirmed_allocation_id;
    select ca.departure_id,(d.journey_pair_id is not null or d.leg_number is not null)
      into v_departure_id,v_paired
    from pace_v2.confirmed_allocations ca
    join pace_v2.departures d on d.id=ca.departure_id
    where ca.id=v_allocation_id;
    if v_paired then
      v_start_changed:=case when tg_op='INSERT' then new.actual_departure_ts is not null
        else new.actual_departure_ts is distinct from old.actual_departure_ts end;
      if v_start_changed then
        select exists(
          select 1
          from pace_v2.journey_pairs pair
          join pace_v2.captain_leg_operations operation
            on operation.confirmed_allocation_id=v_allocation_id
           and (
             (operation.departure_id=pair.outbound_departure_id and operation.legacy_start_authorized)
             or (operation.departure_id=pair.return_departure_id and operation.finalization_authorized)
           )
          where pair.outbound_departure_id=v_departure_id
        ) into v_start_authorized;
        if not v_start_authorized then
          raise exception 'paired duty must be started with v2_captain_start_leg';
        end if;
      end if;
      if tg_op='UPDATE' and new.actual_arrival_ts is not distinct from old.actual_arrival_ts then
        return new;
      end if;
      if tg_op='INSERT' and new.actual_arrival_ts is null then return new; end if;
      select exists(
        select 1
        from pace_v2.journey_pairs pair
        join pace_v2.captain_leg_operations operation
          on operation.confirmed_allocation_id=v_allocation_id
         and operation.departure_id=pair.return_departure_id
         and operation.finalization_authorized
        where pair.outbound_departure_id=v_departure_id
      ) into v_authorized;
    end if;
  end if;

  if v_paired and not v_authorized then
    raise exception 'paired duty must be completed with v2_captain_end_leg';
  end if;
  return new;
end $$;

alter function pace_v2.prevent_paired_legacy_completion() owner to postgres;

drop trigger if exists captain_guard_paired_voyage_completion on pace_v2.voyage_logs;
create trigger captain_guard_paired_voyage_completion
before insert or update of actual_departure_ts,actual_arrival_ts on pace_v2.voyage_logs
for each row execute function pace_v2.prevent_paired_legacy_completion();

drop trigger if exists captain_guard_paired_departure_completion on pace_v2.departures;
create trigger captain_guard_paired_departure_completion
before update of journey_pair_id,leg_number,actual_departure_ts,actual_arrival_ts on pace_v2.departures
for each row execute function pace_v2.prevent_paired_legacy_completion();

revoke all on function pace_v2.prevent_paired_legacy_completion() from public,anon,authenticated;

-- Pair mutations take service row, service-design advisory, outbound advisory,
-- outbound departure, pair, then return departure locks. Captain actions use
-- the same order and revalidate every identity observed before those locks.
create or replace function pace_v2.lock_captain_duty_identity(p_target_departure_id uuid)
returns table(
  target_departure_id uuid,
  outbound_departure_id uuid,
  final_departure_id uuid,
  journey_pair_id uuid
)
language plpgsql security definer set search_path='' as $$
declare
  v_initial pace_v2.departures%rowtype;
  v_revalidated pace_v2.departures%rowtype;
  v_outbound pace_v2.departures%rowtype;
  v_final pace_v2.departures%rowtype;
  v_pair_snapshot pace_v2.journey_pairs%rowtype;
  v_pair_locked pace_v2.journey_pairs%rowtype;
  v_service pace_v2.services%rowtype;
  v_outbound_id uuid;
  v_final_id uuid;
begin
  select * into v_initial from pace_v2.departures departure
  where departure.id=p_target_departure_id;
  if v_initial.id is null then raise exception 'captain assignment required'; end if;

  if v_initial.service_id is not null then
    select * into v_service from pace_v2.services service
    where service.id=v_initial.service_id for update;
    if v_service.id is null then raise exception 'journey pair identity changed; retry action'; end if;
    perform pg_advisory_xact_lock(
      hashtextextended('service-return-design:'||v_initial.service_id::text,0)
    );
  end if;
  select * into v_revalidated from pace_v2.departures departure
  where departure.id=p_target_departure_id;
  if v_revalidated.id is null
     or v_revalidated.service_id is distinct from v_initial.service_id
     or v_revalidated.journey_pair_id is distinct from v_initial.journey_pair_id
     or v_revalidated.leg_number is distinct from v_initial.leg_number then
    raise exception 'journey pair identity changed; retry action';
  end if;

  if v_initial.journey_pair_id is null then
    if v_initial.leg_number is not null then
      raise exception 'journey pair identity changed; retry action';
    end if;
    v_outbound_id:=v_initial.id;
    v_final_id:=v_initial.id;
  else
    select * into v_pair_snapshot from pace_v2.journey_pairs pair
    where pair.id=v_initial.journey_pair_id;
    if v_pair_snapshot.id is null
       or v_initial.id not in(v_pair_snapshot.outbound_departure_id,v_pair_snapshot.return_departure_id) then
      raise exception 'journey pair identity changed; retry action';
    end if;
    v_outbound_id:=v_pair_snapshot.outbound_departure_id;
    v_final_id:=v_pair_snapshot.return_departure_id;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_outbound_id::text,0));
  select * into v_outbound from pace_v2.departures departure
  where departure.id=v_outbound_id for update;

  if v_initial.journey_pair_id is not null then
    select * into v_pair_locked from pace_v2.journey_pairs pair
    where pair.id=v_initial.journey_pair_id for update;
    if v_pair_locked.id is null
       or v_pair_locked.outbound_departure_id is distinct from v_pair_snapshot.outbound_departure_id
       or v_pair_locked.return_departure_id is distinct from v_pair_snapshot.return_departure_id then
      raise exception 'journey pair identity changed; retry action';
    end if;
    select * into v_final from pace_v2.departures departure
    where departure.id=v_final_id for update;
    if v_outbound.id is null or v_final.id is null
       or v_outbound.journey_pair_id is distinct from v_pair_locked.id or v_outbound.leg_number is distinct from 1
       or v_final.journey_pair_id is distinct from v_pair_locked.id or v_final.leg_number is distinct from 2 then
      raise exception 'journey pair identity changed; retry action';
    end if;
  else
    v_final:=v_outbound;
    if v_outbound.id is null or v_outbound.journey_pair_id is not null or v_outbound.leg_number is not null then
      raise exception 'journey pair identity changed; retry action';
    end if;
  end if;

  select * into v_revalidated from pace_v2.departures departure
  where departure.id=p_target_departure_id;
  if v_revalidated.id is null
     or v_revalidated.service_id is distinct from v_initial.service_id
     or v_revalidated.journey_pair_id is distinct from v_initial.journey_pair_id
     or v_revalidated.leg_number is distinct from v_initial.leg_number
     or v_revalidated.id not in(v_outbound_id,v_final_id) then
    raise exception 'journey pair identity changed; retry action';
  end if;

  target_departure_id:=v_revalidated.id;
  outbound_departure_id:=v_outbound_id;
  final_departure_id:=v_final_id;
  journey_pair_id:=v_initial.journey_pair_id;
  return next;
end $$;

alter function pace_v2.lock_captain_duty_identity(uuid) owner to postgres;
revoke all on function pace_v2.lock_captain_duty_identity(uuid) from public,anon,authenticated;

-- Same-day duties remain available as before. A paired duty that actually
-- began before local midnight remains operational only through the bounded
-- recovery window. Exact terminal evidence replay remains available beyond
-- that ceiling only to its original actor; the RPC also verifies its payload.
create or replace function pace_v2.captain_duty_recovery_deadline(
  p_outbound_departure_id uuid,
  p_final_departure_id uuid
)
returns timestamptz language sql stable security definer set search_path='' as $$
  select greatest(
    coalesce(final_leg.scheduled_arrival_ts,outbound.scheduled_arrival_ts,
      outbound.scheduled_departure_ts),
    coalesce(outbound.scheduled_arrival_ts,outbound.scheduled_departure_ts)
  )+interval '24 hours'
  from pace_v2.departures outbound
  join pace_v2.departures final_leg on final_leg.id=p_final_departure_id
  where outbound.id=p_outbound_departure_id
$$;

create or replace function pace_v2.captain_duty_recovery_expired(
  p_confirmed_allocation_id uuid,
  p_outbound_departure_id uuid,
  p_final_departure_id uuid
)
returns boolean language sql stable security definer set search_path='' as $$
  select coalesce((
    select p_outbound_departure_id<>p_final_departure_id
      and operation_1.started_at is not null
      and now()>pace_v2.captain_duty_recovery_deadline(
        p_outbound_departure_id,p_final_departure_id
      )
    from pace_v2.captain_leg_operations operation_1
    where operation_1.confirmed_allocation_id=p_confirmed_allocation_id
      and operation_1.departure_id=p_outbound_departure_id
  ),false)
$$;

create or replace function pace_v2.captain_duty_action_allowed(
  p_confirmed_allocation_id uuid,
  p_target_departure_id uuid,
  p_outbound_departure_id uuid,
  p_final_departure_id uuid,
  p_country_timezone text
)
returns boolean language sql stable security definer set search_path='' as $$
  select coalesce(
    (outbound.scheduled_departure_ts at time zone p_country_timezone)::date
      =(now() at time zone p_country_timezone)::date
    or (
      p_outbound_departure_id<>p_final_departure_id
      and operation_1.started_at is not null
      and operation_1.completion_state is distinct from 'incident'
      and operation_2.ended_at is null
      and now()<=pace_v2.captain_duty_recovery_deadline(
        p_outbound_departure_id,p_final_departure_id
      )
    )
    or (
      target_operation.ended_at is not null
      and target_operation.ended_by_user_id=auth.uid()
    ),false)
  from pace_v2.departures outbound
  left join pace_v2.captain_leg_operations operation_1
    on operation_1.confirmed_allocation_id=p_confirmed_allocation_id
   and operation_1.departure_id=p_outbound_departure_id
  left join pace_v2.captain_leg_operations operation_2
    on operation_2.confirmed_allocation_id=p_confirmed_allocation_id
   and operation_2.departure_id=p_final_departure_id
  left join pace_v2.captain_leg_operations target_operation
    on target_operation.confirmed_allocation_id=p_confirmed_allocation_id
   and target_operation.departure_id=p_target_departure_id
  where outbound.id=p_outbound_departure_id
$$;
revoke all on function pace_v2.captain_duty_recovery_deadline(uuid,uuid),
  pace_v2.captain_duty_recovery_expired(uuid,uuid,uuid)
from public,anon,authenticated;
revoke all on function pace_v2.captain_duty_action_allowed(uuid,uuid,uuid,uuid,text)
from public,anon,authenticated;

create or replace function pace_v2.captain_today_duties()
returns table(
  duty_id uuid,
  journey_pair_id uuid,
  confirmed_allocation_id uuid,
  captain_assignment_id uuid,
  country_timezone text,
  first_scheduled_departure_ts timestamptz,
  leg_1_departure_id uuid,
  leg_1_name text,
  pickup_name text,
  leg_1_scheduled_departure_ts timestamptz,
  leg_1_scheduled_arrival_ts timestamptz,
  leg_1_started_at timestamptz,
  leg_1_ended_at timestamptz,
  leg_1_completion_state text,
  leg_1_started_by_user_id uuid,
  leg_1_ended_by_user_id uuid,
  leg_1_notes text,
  leg_1_incident_summary text,
  leg_2_departure_id uuid,
  leg_2_name text,
  leg_2_scheduled_departure_ts timestamptz,
  leg_2_scheduled_arrival_ts timestamptz,
  leg_2_started_at timestamptz,
  leg_2_ended_at timestamptz,
  leg_2_completion_state text,
  leg_2_started_by_user_id uuid,
  leg_2_ended_by_user_id uuid,
  leg_2_notes text,
  leg_2_incident_summary text,
  vehicle_id uuid,
  vehicle_name text,
  operator_id uuid,
  operator_name text,
  captain_id uuid,
  captain_name text,
  duty_state text
)
language sql stable security definer set search_path='' as $$
  select
    ca.id as duty_id,
    duty_departure.journey_pair_id,
    ca.id,
    assignment.id,
    country.timezone as country_timezone,
    duty_departure.scheduled_departure_ts,
    duty_departure.id,
    coalesce(route_1.route_name,route_1.name),
    pickup_1.name as pickup_name,
    duty_departure.scheduled_departure_ts,
    duty_departure.scheduled_arrival_ts,
    coalesce(operation_1.started_at,legacy_actual_departure_ts),
    coalesce(operation_1.ended_at,legacy_actual_arrival_ts),
    coalesce(operation_1.completion_state,legacy_completion_state),
    operation_1.started_by_user_id,
    operation_1.ended_by_user_id,
    coalesce(operation_1.notes,legacy_notes),
    case when coalesce(operation_1.completion_state,legacy_completion_state)='incident'
      then coalesce(operation_1.incident_summary,legacy_incident_summary) end,
    leg_2.id,
    coalesce(route_2.route_name,route_2.name),
    leg_2.scheduled_departure_ts,
    leg_2.scheduled_arrival_ts,
    operation_2.started_at,
    operation_2.ended_at,
    operation_2.completion_state,
    operation_2.started_by_user_id,
    operation_2.ended_by_user_id,
    operation_2.notes,
    operation_2.incident_summary,
    vehicle.id,
    vehicle.name,
    assigned_operator.id,
    assigned_operator.name,
    captain.id,
    concat_ws(' ',captain.first_name,captain.last_name),
    case
      when coalesce(operation_1.completion_state,legacy_completion_state)='incident'
        or operation_2.completion_state='incident' then 'incident'
      when leg_2.id is null and coalesce(operation_1.ended_at,legacy_actual_arrival_ts) is not null then 'completed'
      when leg_2.id is not null and operation_2.ended_at is not null then 'completed'
      when leg_2.id is not null and operation_2.started_at is not null then 'leg_2_in_progress'
      when leg_2.id is not null and operation_1.ended_at is not null then 'awaiting_leg_2'
      when coalesce(operation_1.started_at,legacy_actual_departure_ts) is not null then 'leg_1_in_progress'
      else 'ready'
    end as duty_state
  from pace_v2.confirmed_allocations ca
  join pace_v2.departures duty_departure on duty_departure.id=ca.departure_id
    and (duty_departure.journey_pair_id is null or duty_departure.leg_number=1)
  left join pace_v2.journey_pairs pair on pair.id=duty_departure.journey_pair_id
    and pair.outbound_departure_id=duty_departure.id
  left join pace_v2.departures leg_2 on leg_2.id=pair.return_departure_id
    and leg_2.journey_pair_id=pair.id and leg_2.leg_number=2
  join pace_v2.routes route_1 on route_1.id=duty_departure.route_id
  join pace_v2.pickup_points pickup_1 on pickup_1.id=route_1.pickup_id
  left join pace_v2.routes route_2 on route_2.id=leg_2.route_id
  join pace_v2.countries country on country.id=route_1.country_id
  join pg_catalog.pg_timezone_names valid_timezone on valid_timezone.name=country.timezone
  join pace_v2.vehicles vehicle on vehicle.id=ca.vehicle_id and vehicle.active
  join pace_v2.operators assigned_operator on assigned_operator.id=ca.operator_id and assigned_operator.active
  join pace_v2.captain_assignments assignment
    on assignment.confirmed_allocation_id=ca.id and assignment.active
  join pace_v2.captains captain on captain.id=assignment.captain_id
    and captain.active and captain.operator_id=ca.operator_id and captain.auth_user_id=auth.uid()
  join pace_v2.captain_vehicle_types eligibility on eligibility.captain_id=captain.id
    and eligibility.vehicle_type_id=vehicle.vehicle_type_id and eligibility.active
  left join pace_v2.captain_leg_operations operation_1
    on operation_1.confirmed_allocation_id=ca.id and operation_1.departure_id=duty_departure.id
  left join pace_v2.captain_leg_operations operation_2
    on operation_2.confirmed_allocation_id=ca.id and operation_2.departure_id=leg_2.id
  left join lateral(
    select to_jsonb(voyage) as payload
    from pace_v2.voyage_logs voyage
    where voyage.confirmed_allocation_id=ca.id
    order by voyage.created_at desc
    limit 1
  ) legacy_log on true
  cross join lateral(
    select
      case when duty_departure.journey_pair_id is null then
        coalesce((legacy_log.payload->>'actual_departure_ts')::timestamptz,duty_departure.actual_departure_ts)
      end as legacy_actual_departure_ts,
      case when duty_departure.journey_pair_id is null then
        coalesce((legacy_log.payload->>'actual_arrival_ts')::timestamptz,duty_departure.actual_arrival_ts)
      end as legacy_actual_arrival_ts,
      case when duty_departure.journey_pair_id is null
             and coalesce((legacy_log.payload->>'actual_arrival_ts')::timestamptz,duty_departure.actual_arrival_ts) is not null
        then case when coalesce((legacy_log.payload->>'incident_flag')::boolean,false) then 'incident' else 'normal' end
      end as legacy_completion_state,
      case when duty_departure.journey_pair_id is null then legacy_log.payload->>'captain_notes' end as legacy_notes,
      case when duty_departure.journey_pair_id is null
             and coalesce((legacy_log.payload->>'incident_flag')::boolean,false)
        then legacy_log.payload->>'incident_summary' end as legacy_incident_summary
  ) legacy
  where auth.uid() is not null and ca.status='confirmed'
    and case when valid_timezone.name is not null then
      (duty_departure.scheduled_departure_ts at time zone country.timezone)::date
        = (now() at time zone country.timezone)::date
      or (
        leg_2.id is not null
        and operation_1.started_at is not null
        and operation_1.completion_state is distinct from 'incident'
        and operation_2.ended_at is null
        and now()<=pace_v2.captain_duty_recovery_deadline(
          duty_departure.id,leg_2.id
        )
      )
      else false
    end
$$;

create or replace function pace_v2.captain_today_manifest()
returns table(
  duty_id uuid,
  journey_pair_id uuid,
  confirmed_allocation_id uuid,
  leg_1_departure_id uuid,
  leg_2_departure_id uuid,
  booking_id uuid,
  lead_passenger_name text,
  adult_count integer,
  child_count integer,
  infant_count integer,
  payment_status text,
  special_requirements_present boolean,
  unread_count integer,
  passengers jsonb
)
language sql stable security definer set search_path='' as $$
  select
    duty.duty_id,
    duty.journey_pair_id,
    duty.confirmed_allocation_id,
    duty.leg_1_departure_id,
    duty.leg_2_departure_id,
    b.id,
    coalesce(
      nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_name','')),''),
      nullif(trim(concat_ws(' ',lead_party.first_name,lead_party.last_name)),''),
      'Booking party'
    ),
    count(*) filter(where p.id is not null and coalesce(p.age_group,'adult')='adult')::integer,
    count(*) filter(where p.id is not null and p.age_group='child')::integer,
    count(*) filter(where p.id is not null and p.age_group='infant')::integer,
    orders.payment_status::text,
    coalesce(bool_or(nullif(trim(p.notes),'') is not null),false),
    coalesce(unread.unread_count,0),
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'first_name',p.first_name,
          'last_name',p.last_name,
          'age_group',coalesce(p.age_group,'adult'),
          'notes',p.notes
        ) order by p.id
      ) filter(where p.id is not null),
      '[]'::jsonb
    )
  from pace_v2.captain_today_duties() duty
  join pace_v2.confirmed_allocations ca on ca.id=duty.confirmed_allocation_id
  join pace_v2.booking_allocations booking_allocation
    on booking_allocation.vehicle_consideration_id=ca.consideration_id
  join pace_v2.bookings b on b.id=booking_allocation.booking_id
    and pace_v2.is_active_paid_journey_booking(b.id,null)
  join pace_v2.orders orders on orders.id=b.order_id
  left join lateral(
    select pace_v2.authorized_journey_conversation_unread_count(conversation.id,'captain') as unread_count
    from pace_v2.journey_conversations conversation
    where conversation.booking_id=b.id
      and conversation.confirmed_allocation_id=duty.confirmed_allocation_id
    limit 1
  ) unread on true
  left join lateral(
    select lead_passenger.first_name,lead_passenger.last_name
    from pace_v2.passengers lead_passenger
    where lead_passenger.booking_id=b.id
    order by lead_passenger.id
    limit 1
  ) lead_party on true
  left join pace_v2.passengers p on p.booking_id=b.id
  group by duty.duty_id,duty.journey_pair_id,duty.confirmed_allocation_id,
    duty.leg_1_departure_id,duty.leg_2_departure_id,b.id,orders.payment_status,
    unread.unread_count,lead_party.first_name,lead_party.last_name
$$;

create or replace view public.v2_captain_today_duties with (security_barrier=true,security_invoker=true) as
select * from pace_v2.captain_today_duties();

create or replace view public.v2_captain_today_manifest with (security_barrier=true,security_invoker=true) as
select * from pace_v2.captain_today_manifest();

revoke all on function pace_v2.captain_today_duties(),pace_v2.captain_today_manifest() from public,anon;
grant execute on function pace_v2.captain_today_duties(),pace_v2.captain_today_manifest() to authenticated;
revoke all on public.v2_captain_today_duties,public.v2_captain_today_manifest from public,anon;
grant select on public.v2_captain_today_duties to authenticated;
grant select on public.v2_captain_today_manifest to authenticated;

create or replace function public.v2_captain_start_leg(p_departure_id uuid)
returns timestamptz
language plpgsql security definer set search_path='' as $$
declare
  target_leg pace_v2.departures%rowtype;
  outbound_departure pace_v2.departures%rowtype;
  existing_operation pace_v2.captain_leg_operations%rowtype;
  previous_operation pace_v2.captain_leg_operations%rowtype;
  v_outbound_id uuid;
  v_final_id uuid;
  v_allocation_id uuid;
  v_assignment_id uuid;
  v_candidate_count integer;
  country_timezone text;
  v_started_at timestamptz;
  v_legacy_started_at timestamptz;
  v_legacy_ended_at timestamptz;
  v_legacy_completion_state text;
  v_legacy_notes text;
  v_legacy_summary text;
  v_locked_identity record;
begin
  if auth.uid() is null then raise exception 'captain assignment required'; end if;
  select * into v_locked_identity from pace_v2.lock_captain_duty_identity(p_departure_id);
  v_outbound_id:=v_locked_identity.outbound_departure_id;
  v_final_id:=v_locked_identity.final_departure_id;
  select * into target_leg from pace_v2.departures where id=v_locked_identity.target_departure_id;
  select * into outbound_departure from pace_v2.departures where id=v_outbound_id;
  if target_leg.id is distinct from v_locked_identity.target_departure_id
     or target_leg.id not in(v_outbound_id,v_final_id) then
    raise exception 'journey pair identity changed; retry action';
  end if;

  perform ca.id
  from pace_v2.confirmed_allocations ca
  join pace_v2.departures allocation_departure on ca.departure_id=allocation_departure.id
  join pace_v2.vehicles vehicle on vehicle.id=ca.vehicle_id and vehicle.active
  join pace_v2.captain_assignments assignment
    on assignment.confirmed_allocation_id=ca.id and assignment.active
  join pace_v2.captains captain on captain.id=assignment.captain_id
    and captain.active and captain.operator_id=ca.operator_id and captain.auth_user_id=auth.uid()
  join pace_v2.captain_vehicle_types eligibility on eligibility.captain_id=captain.id
    and eligibility.vehicle_type_id=vehicle.vehicle_type_id and eligibility.active
  where allocation_departure.id=v_outbound_id and ca.status in('confirmed','completed')
  order by ca.id,assignment.id for update of ca,assignment;

  select count(*),
    (array_agg(ca.id order by ca.id,assignment.id))[1],
    (array_agg(assignment.id order by ca.id,assignment.id))[1],
    (array_agg(country.timezone order by ca.id,assignment.id))[1]
    into v_candidate_count,v_allocation_id,v_assignment_id,country_timezone
  from pace_v2.confirmed_allocations ca
  join pace_v2.departures allocation_departure on ca.departure_id=allocation_departure.id
  join pace_v2.routes route on route.id=allocation_departure.route_id
  join pace_v2.countries country on country.id=route.country_id
  join pace_v2.vehicles vehicle on vehicle.id=ca.vehicle_id and vehicle.active
  join pace_v2.captain_assignments assignment
    on assignment.confirmed_allocation_id=ca.id and assignment.active
  join pace_v2.captains captain on captain.id=assignment.captain_id
    and captain.active and captain.operator_id=ca.operator_id and captain.auth_user_id=auth.uid()
  join pace_v2.captain_vehicle_types eligibility on eligibility.captain_id=captain.id
    and eligibility.vehicle_type_id=vehicle.vehicle_type_id and eligibility.active
  where allocation_departure.id=v_outbound_id and ca.status in('confirmed','completed');
  if v_candidate_count=0 then raise exception 'captain assignment required'; end if;
  if v_candidate_count>1 then raise exception 'captain duty is ambiguous for departure'; end if;
  if not exists(select 1 from pg_catalog.pg_timezone_names timezone_name where timezone_name.name=country_timezone) then
    raise exception 'captain duty timezone is invalid';
  end if;
  if not pace_v2.captain_duty_action_allowed(v_allocation_id,target_leg.id,v_outbound_id,v_final_id,country_timezone) then
    if pace_v2.captain_duty_recovery_expired(v_allocation_id,v_outbound_id,v_final_id) then
      raise exception 'captain duty recovery window expired; escalate to Site Admin';
    end if;
    raise exception 'captain duty is not operating today';
  end if;

  if target_leg.journey_pair_id is null then
    select
      coalesce((legacy.payload->>'actual_departure_ts')::timestamptz,target_leg.actual_departure_ts),
      coalesce((legacy.payload->>'actual_arrival_ts')::timestamptz,target_leg.actual_arrival_ts),
      case when coalesce((legacy.payload->>'actual_arrival_ts')::timestamptz,target_leg.actual_arrival_ts) is not null
        then case when coalesce((legacy.payload->>'incident_flag')::boolean,false) then 'incident' else 'normal' end
      end,
      legacy.payload->>'captain_notes',legacy.payload->>'incident_summary'
      into v_legacy_started_at,v_legacy_ended_at,v_legacy_completion_state,v_legacy_notes,v_legacy_summary
    from pace_v2.departures legacy_departure
    left join lateral(
      select to_jsonb(voyage) payload from pace_v2.voyage_logs voyage
      where voyage.confirmed_allocation_id=v_allocation_id
      order by voyage.created_at desc limit 1
    ) legacy on true
    where legacy_departure.id=target_leg.id;
  end if;

  insert into pace_v2.captain_leg_operations(
    confirmed_allocation_id,departure_id,captain_assignment_id,started_at,ended_at,
    completion_state,notes,incident_summary
  ) values(
    v_allocation_id,target_leg.id,v_assignment_id,v_legacy_started_at,v_legacy_ended_at,
    v_legacy_completion_state,v_legacy_notes,
    case when v_legacy_completion_state='incident' then v_legacy_summary else null end
  ) on conflict(confirmed_allocation_id,departure_id) do nothing;
  select * into existing_operation from pace_v2.captain_leg_operations
  where confirmed_allocation_id=v_allocation_id and departure_id=target_leg.id for update;
  if existing_operation.started_at is not null then
    if (target_leg.journey_pair_id is not null
         and existing_operation.started_by_user_id is distinct from auth.uid())
       or (existing_operation.ended_at is null
         and existing_operation.captain_assignment_id<>v_assignment_id) then
      raise exception 'captain assignment required';
    end if;
    return existing_operation.started_at;
  end if;
  if existing_operation.captain_assignment_id<>v_assignment_id then
    raise exception 'captain assignment required';
  end if;

  if target_leg.id<>v_outbound_id then
    select * into previous_operation from pace_v2.captain_leg_operations
    where confirmed_allocation_id=v_allocation_id and departure_id=v_outbound_id for update;
    if previous_operation.ended_at is null then raise exception 'leg transition out of order'; end if;
    if previous_operation.completion_state='incident' then
      raise exception 'incident-ended duty cannot start another leg; escalate to Site Admin';
    end if;
  end if;

  if target_leg.id=v_outbound_id then
    update pace_v2.captain_leg_operations
    set legacy_start_authorized=true
    where confirmed_allocation_id=v_allocation_id and departure_id=target_leg.id
      and started_at is null and ended_at is null;
    perform public.v2_captain_start_journey(p_captain_assignment_id=>v_assignment_id);
    update pace_v2.captain_leg_operations
    set legacy_start_authorized=false
    where confirmed_allocation_id=v_allocation_id and departure_id=target_leg.id;
    select coalesce((legacy.payload->>'actual_departure_ts')::timestamptz,departure.actual_departure_ts)
      into v_legacy_started_at
    from pace_v2.departures departure
    left join lateral(
      select to_jsonb(voyage) payload from pace_v2.voyage_logs voyage
      where voyage.confirmed_allocation_id=v_allocation_id
      order by voyage.created_at desc limit 1
    ) legacy on true
    where departure.id=v_outbound_id;
  end if;
  v_started_at:=coalesce(v_legacy_started_at,clock_timestamp());
  update pace_v2.captain_leg_operations
  set started_at=v_started_at,started_by_user_id=auth.uid(),legacy_start_authorized=false
  where confirmed_allocation_id=v_allocation_id and departure_id=target_leg.id and started_at is null;
  return v_started_at;
end $$;

create or replace function public.v2_captain_end_leg(
  p_departure_id uuid,
  p_completion_state text,
  p_notes text,
  p_incident_summary text
)
returns timestamptz
language plpgsql security definer set search_path='' as $$
declare
  target_leg pace_v2.departures%rowtype;
  outbound_departure pace_v2.departures%rowtype;
  final_leg pace_v2.departures%rowtype;
  existing_operation pace_v2.captain_leg_operations%rowtype;
  previous_operation pace_v2.captain_leg_operations%rowtype;
  v_outbound_id uuid;
  v_final_id uuid;
  v_allocation_id uuid;
  v_assignment_id uuid;
  v_candidate_count integer;
  country_timezone text;
  v_ended_at timestamptz;
  v_legacy_started_at timestamptz;
  v_legacy_ended_at timestamptz;
  v_legacy_completion_state text;
  v_legacy_notes text;
  v_legacy_summary text;
  v_incident_summary text;
  v_all_allocations_finished boolean:=false;
  v_locked_identity record;
  v_finalization record;
  v_original_auth_user text:=coalesce(current_setting('request.jwt.claim.sub',true),'');
begin
  if auth.uid() is null then raise exception 'captain assignment required'; end if;
  select * into v_locked_identity from pace_v2.lock_captain_duty_identity(p_departure_id);
  v_outbound_id:=v_locked_identity.outbound_departure_id;
  v_final_id:=v_locked_identity.final_departure_id;
  select * into target_leg from pace_v2.departures where id=v_locked_identity.target_departure_id;
  select * into outbound_departure from pace_v2.departures where id=v_outbound_id;
  select * into final_leg from pace_v2.departures where id=v_final_id;
  if target_leg.id is distinct from v_locked_identity.target_departure_id
     or target_leg.id not in(v_outbound_id,v_final_id)
     or final_leg.id is distinct from v_locked_identity.final_departure_id then
    raise exception 'journey pair identity changed; retry action';
  end if;

  perform ca.id
  from pace_v2.confirmed_allocations ca
  join pace_v2.departures allocation_departure on ca.departure_id=allocation_departure.id
  join pace_v2.vehicles vehicle on vehicle.id=ca.vehicle_id and vehicle.active
  join pace_v2.captain_assignments assignment
    on assignment.confirmed_allocation_id=ca.id and assignment.active
  join pace_v2.captains captain on captain.id=assignment.captain_id
    and captain.active and captain.operator_id=ca.operator_id and captain.auth_user_id=auth.uid()
  join pace_v2.captain_vehicle_types eligibility on eligibility.captain_id=captain.id
    and eligibility.vehicle_type_id=vehicle.vehicle_type_id and eligibility.active
  where allocation_departure.id=v_outbound_id and ca.status in('confirmed','completed')
  order by ca.id,assignment.id for update of ca,assignment;

  select count(*),
    (array_agg(ca.id order by ca.id,assignment.id))[1],
    (array_agg(assignment.id order by ca.id,assignment.id))[1],
    (array_agg(country.timezone order by ca.id,assignment.id))[1]
    into v_candidate_count,v_allocation_id,v_assignment_id,country_timezone
  from pace_v2.confirmed_allocations ca
  join pace_v2.departures allocation_departure on ca.departure_id=allocation_departure.id
  join pace_v2.routes route on route.id=allocation_departure.route_id
  join pace_v2.countries country on country.id=route.country_id
  join pace_v2.vehicles vehicle on vehicle.id=ca.vehicle_id and vehicle.active
  join pace_v2.captain_assignments assignment
    on assignment.confirmed_allocation_id=ca.id and assignment.active
  join pace_v2.captains captain on captain.id=assignment.captain_id
    and captain.active and captain.operator_id=ca.operator_id and captain.auth_user_id=auth.uid()
  join pace_v2.captain_vehicle_types eligibility on eligibility.captain_id=captain.id
    and eligibility.vehicle_type_id=vehicle.vehicle_type_id and eligibility.active
  where allocation_departure.id=v_outbound_id and ca.status in('confirmed','completed');
  if v_candidate_count=0 then raise exception 'captain assignment required'; end if;
  if v_candidate_count>1 then raise exception 'captain duty is ambiguous for departure'; end if;
  if not exists(select 1 from pg_catalog.pg_timezone_names timezone_name where timezone_name.name=country_timezone) then
    raise exception 'captain duty timezone is invalid';
  end if;
  if not pace_v2.captain_duty_action_allowed(v_allocation_id,target_leg.id,v_outbound_id,v_final_id,country_timezone) then
    if pace_v2.captain_duty_recovery_expired(v_allocation_id,v_outbound_id,v_final_id) then
      raise exception 'captain duty recovery window expired; escalate to Site Admin';
    end if;
    raise exception 'captain duty is not operating today';
  end if;
  if p_completion_state is null or p_completion_state not in ('normal','incident') then
    raise exception 'invalid completion state';
  end if;
  if p_completion_state='incident'
     and nullif(trim(coalesce(p_incident_summary,'')),'') is null then
    raise exception 'incident summary required';
  end if;
  if p_completion_state='normal'
     and nullif(trim(coalesce(p_incident_summary,'')),'') is not null then
    raise exception 'normal completion cannot include an incident summary';
  end if;
  v_incident_summary:=case when p_completion_state='incident' then p_incident_summary else null end;

  if target_leg.journey_pair_id is null then
    select
      coalesce((legacy.payload->>'actual_departure_ts')::timestamptz,target_leg.actual_departure_ts),
      coalesce((legacy.payload->>'actual_arrival_ts')::timestamptz,target_leg.actual_arrival_ts),
      case when coalesce((legacy.payload->>'actual_arrival_ts')::timestamptz,target_leg.actual_arrival_ts) is not null
        then case when coalesce((legacy.payload->>'incident_flag')::boolean,false) then 'incident' else 'normal' end
      end,
      legacy.payload->>'captain_notes',legacy.payload->>'incident_summary'
      into v_legacy_started_at,v_legacy_ended_at,v_legacy_completion_state,v_legacy_notes,v_legacy_summary
    from pace_v2.departures legacy_departure
    left join lateral(
      select to_jsonb(voyage) payload from pace_v2.voyage_logs voyage
      where voyage.confirmed_allocation_id=v_allocation_id
      order by voyage.created_at desc limit 1
    ) legacy on true
    where legacy_departure.id=target_leg.id;
    insert into pace_v2.captain_leg_operations(
      confirmed_allocation_id,departure_id,captain_assignment_id,started_at,ended_at,
      completion_state,notes,incident_summary
    ) values(
      v_allocation_id,target_leg.id,v_assignment_id,v_legacy_started_at,v_legacy_ended_at,
      v_legacy_completion_state,v_legacy_notes,
      case when v_legacy_completion_state='incident' then v_legacy_summary else null end
    ) on conflict(confirmed_allocation_id,departure_id) do nothing;
    if v_legacy_ended_at is not null then
      update pace_v2.captain_leg_operations
      set started_at=coalesce(started_at,v_legacy_started_at),ended_at=v_legacy_ended_at,
          completion_state=v_legacy_completion_state,notes=v_legacy_notes,
          incident_summary=case when v_legacy_completion_state='incident' then v_legacy_summary else null end,
          finalization_authorized=false
      where confirmed_allocation_id=v_allocation_id and departure_id=target_leg.id
        and ended_at is null;
    end if;
  end if;

  select * into existing_operation from pace_v2.captain_leg_operations
  where confirmed_allocation_id=v_allocation_id and departure_id=target_leg.id for update;
  if existing_operation.departure_id is null or existing_operation.started_at is null then
    raise exception 'leg transition out of order';
  end if;
  if existing_operation.ended_at is not null then
    if target_leg.journey_pair_id is not null
       and existing_operation.ended_by_user_id is distinct from auth.uid() then
      raise exception 'captain assignment required';
    end if;
    if existing_operation.completion_state is distinct from p_completion_state
       or existing_operation.notes is distinct from p_notes
       or existing_operation.incident_summary is distinct from v_incident_summary then
      raise exception 'leg completion evidence already recorded';
    end if;
    return existing_operation.ended_at;
  end if;
  if existing_operation.captain_assignment_id<>v_assignment_id then
    raise exception 'captain assignment required';
  end if;

  if target_leg.id<>v_outbound_id then
    select * into previous_operation from pace_v2.captain_leg_operations
    where confirmed_allocation_id=v_allocation_id and departure_id=v_outbound_id for update;
    if previous_operation.ended_at is null then raise exception 'leg transition out of order'; end if;
    if previous_operation.completion_state='incident' then
      raise exception 'incident-ended duty cannot start another leg; escalate to Site Admin';
    end if;
  end if;

  -- Persist the caller's immutable server evidence first. If any later legacy
  -- integration fails, the transaction rolls this write back with it.
  v_ended_at:=clock_timestamp();
  update pace_v2.captain_leg_operations
  set ended_at=v_ended_at,completion_state=p_completion_state,
      notes=p_notes,incident_summary=v_incident_summary,ended_by_user_id=auth.uid(),
      finalization_authorized=false
  where confirmed_allocation_id=v_allocation_id and departure_id=target_leg.id
    and ended_at is null;

  if target_leg.id=final_leg.id then
    perform allocation.id
    from pace_v2.confirmed_allocations allocation
    where allocation.departure_id=v_outbound_id and allocation.status='confirmed'
    order by allocation.id for update;

    select not exists(
      select 1
      from pace_v2.confirmed_allocations allocation
      left join pace_v2.captain_leg_operations operation
        on operation.confirmed_allocation_id=allocation.id
       and operation.departure_id=v_final_id
      where allocation.departure_id=v_outbound_id
        and allocation.status='confirmed'
        and operation.ended_at is null
    ) into v_all_allocations_finished;

    if v_all_allocations_finished then
      -- Every allocation owns independent voyage/settlement/feedback evidence.
      -- The outbound advisory lock plus ordered allocation row locks ensure the
      -- batch runs once; exact RPC retries return above without duplicating it.
      for v_finalization in
        select allocation.id as allocation_id,integration.assignment_id,
          integration.assignment_count,integration.captain_user_id,
          operation.completion_state,operation.notes,operation.incident_summary
        from pace_v2.confirmed_allocations allocation
        join pace_v2.captain_leg_operations operation
          on operation.confirmed_allocation_id=allocation.id
         and operation.departure_id=v_final_id and operation.ended_at is not null
        left join lateral(
          select candidate.assignment_id,candidate.captain_user_id,
            count(*) over() as assignment_count
          from (
            select distinct integration_assignment.id as assignment_id,
              integration_captain.auth_user_id as captain_user_id
            from pace_v2.captain_assignments integration_assignment
            join pace_v2.captains integration_captain
              on integration_captain.id=integration_assignment.captain_id
             and integration_captain.active
             and integration_captain.operator_id=allocation.operator_id
             and integration_captain.auth_user_id is not null
            join pace_v2.vehicles integration_vehicle
              on integration_vehicle.id=allocation.vehicle_id and integration_vehicle.active
            join pace_v2.captain_vehicle_types integration_eligibility
              on integration_eligibility.captain_id=integration_captain.id
             and integration_eligibility.vehicle_type_id=integration_vehicle.vehicle_type_id
             and integration_eligibility.active
            where integration_assignment.confirmed_allocation_id=allocation.id
              and integration_assignment.active
          ) candidate
          order by candidate.assignment_id
          limit 1
        ) integration on true
        where allocation.departure_id=v_outbound_id
          and allocation.status='confirmed'
        order by allocation.id
      loop
        if v_finalization.assignment_id is null
           or v_finalization.assignment_count<>1
           or v_finalization.captain_user_id is null then
          raise exception 'confirmed allocation has no active eligible integration assignment';
        end if;
        -- A completed leg may have been reassigned before the final shared
        -- allocation finishes. Its ended final-leg evidence authorizes this
        -- atomic, idempotent start-then-complete integration for the current
        -- assignment without violating the start-only operation row shape.
        update pace_v2.captain_leg_operations
        set finalization_authorized=true
        where confirmed_allocation_id=v_finalization.allocation_id
          and departure_id=v_final_id;
        perform set_config('request.jwt.claim.sub',v_finalization.captain_user_id::text,true);
        perform public.v2_captain_start_journey(
          p_captain_assignment_id=>v_finalization.assignment_id
        );
        perform public.v2_captain_complete_journey(
          p_captain_assignment_id=>v_finalization.assignment_id,
          p_completed_normally=>(v_finalization.completion_state='normal'),
          p_captain_notes=>v_finalization.notes,
          p_incident_flag=>(v_finalization.completion_state='incident'),
          p_incident_summary=>v_finalization.incident_summary
        );
        update pace_v2.captain_leg_operations
        set finalization_authorized=false
        where confirmed_allocation_id=v_finalization.allocation_id
          and departure_id=v_final_id;
      end loop;
      perform set_config('request.jwt.claim.sub',v_original_auth_user,true);
    end if;
  end if;
  return v_ended_at;
end $$;

create table pace_v2.captain_private_message_requests(
  request_id uuid primary key,
  confirmed_allocation_id uuid not null references pace_v2.confirmed_allocations(id),
  booking_id uuid not null references pace_v2.bookings(id),
  captain_id uuid not null references pace_v2.captains(id),
  captain_user_id uuid not null references auth.users(id),
  message_text text not null check(length(trim(message_text)) between 1 and 4000),
  category text not null check(category in('late_running','pickup_change','weather','safety','operational')),
  conversation_id uuid references pace_v2.journey_conversations(id),
  message_id uuid unique references pace_v2.journey_conversation_messages(id),
  created_at timestamptz not null default now(),
  constraint captain_private_message_request_completion_check check(
    (conversation_id is null and message_id is null)
    or (conversation_id is not null and message_id is not null)
  )
);
alter table pace_v2.captain_private_message_requests enable row level security;
revoke all on table pace_v2.captain_private_message_requests from public,anon,authenticated;

create or replace function public.v2_captain_open_party_conversation(
  p_confirmed_allocation_id uuid,
  p_booking_id uuid,
  p_message_text text,
  p_category text,
  p_request_id uuid
)
returns uuid
language plpgsql security definer set search_path='' as $$
declare
  v_user_id uuid:=auth.uid();
  v_captain_id uuid;
  v_conversation_id uuid;
  v_message_id uuid;
  v_created_request_id uuid;
  v_message_text text:=trim(p_message_text);
  v_existing_request pace_v2.captain_private_message_requests%rowtype;
begin
  if v_user_id is null then raise exception 'authentication required'; end if;
  if p_request_id is null then raise exception 'private message request id required'; end if;
  if p_message_text is null or length(trim(p_message_text)) not between 1 and 4000 then
    raise exception 'message text must be between 1 and 4000 characters';
  end if;
  if p_category not in ('late_running','pickup_change','weather','safety','operational') then
    raise exception 'invalid captain message category';
  end if;

  -- A completed request is an immutable result, so its authenticated owner may
  -- recover that result even after the live messaging window has closed.
  select * into v_existing_request
  from pace_v2.captain_private_message_requests
  where request_id=p_request_id
  for update;
  if v_existing_request.request_id is not null then
    if v_existing_request.confirmed_allocation_id is distinct from p_confirmed_allocation_id
       or v_existing_request.booking_id is distinct from p_booking_id
       or v_existing_request.captain_user_id is distinct from v_user_id
       or v_existing_request.message_text is distinct from v_message_text
       or v_existing_request.category is distinct from p_category then
      raise exception 'private message request belongs to another captain, allocation, booking or payload';
    end if;
    if v_existing_request.conversation_id is null or v_existing_request.message_id is null then
      raise exception 'private message request is incomplete';
    end if;
    return v_existing_request.conversation_id;
  end if;

  select c.id into v_captain_id
  from pace_v2.confirmed_allocations ca
  join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
  join pace_v2.captain_assignments a
    on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains c
    on c.id=a.captain_id and c.active and c.operator_id=ca.operator_id
   and c.auth_user_id=v_user_id
  join pace_v2.captain_vehicle_types cvt
    on cvt.captain_id=c.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
  join pace_v2.booking_allocations ba
    on ba.vehicle_consideration_id=ca.consideration_id
  join pace_v2.bookings b on b.id=ba.booking_id
  where ca.id=p_confirmed_allocation_id
    and b.id=p_booking_id
    and ca.status='confirmed'
    and pace_v2.is_active_paid_journey_booking(b.id,null)
  order by a.id
  limit 1;

  if v_captain_id is null then
    raise exception 'journey party not assigned to captain';
  end if;
  if not pace_v2.is_journey_message_window_open(p_confirmed_allocation_id,now()) then
    raise exception 'journey messaging window is closed';
  end if;

  insert into pace_v2.captain_private_message_requests(
    request_id,confirmed_allocation_id,booking_id,captain_id,captain_user_id,message_text,category
  ) values(
    p_request_id,p_confirmed_allocation_id,p_booking_id,v_captain_id,v_user_id,v_message_text,p_category
  )
  on conflict(request_id) do nothing
  returning request_id into v_created_request_id;

  if v_created_request_id is null then
    select * into v_existing_request
    from pace_v2.captain_private_message_requests
    where request_id=p_request_id
    for update;
    if v_existing_request.confirmed_allocation_id is distinct from p_confirmed_allocation_id
       or v_existing_request.booking_id is distinct from p_booking_id
       or v_existing_request.captain_id is distinct from v_captain_id
       or v_existing_request.captain_user_id is distinct from v_user_id
       or v_existing_request.message_text is distinct from v_message_text
       or v_existing_request.category is distinct from p_category then
      raise exception 'private message request belongs to another captain, allocation, booking or payload';
    end if;
    if v_existing_request.conversation_id is null or v_existing_request.message_id is null then
      raise exception 'private message request is incomplete';
    end if;
    return v_existing_request.conversation_id;
  end if;

  insert into pace_v2.journey_conversations(
    booking_id,confirmed_allocation_id,status,opened_at
  ) values(p_booking_id,p_confirmed_allocation_id,'open',now())
  on conflict(booking_id,confirmed_allocation_id) do update
    set status='open',
        opened_at=coalesce(pace_v2.journey_conversations.opened_at,excluded.opened_at),
        closed_at=null
  returning id into v_conversation_id;

  insert into pace_v2.journey_conversation_messages(
    conversation_id,sender_type,sender_user_id,category,message_text
  ) values(v_conversation_id,'captain',v_user_id,p_category,v_message_text)
  returning id into v_message_id;

  update pace_v2.captain_private_message_requests
  set conversation_id=v_conversation_id,message_id=v_message_id
  where request_id=p_request_id;

  return v_conversation_id;
end $$;

revoke all on function public.v2_captain_start_leg(uuid) from public,anon;
revoke all on function public.v2_captain_end_leg(uuid,text,text,text) from public,anon;
revoke all on function public.v2_captain_open_party_conversation(uuid,uuid,text,text,uuid) from public,anon,authenticated;
grant execute on function public.v2_captain_start_leg(uuid) to authenticated;
grant execute on function public.v2_captain_end_leg(uuid,text,text,text) to authenticated;
grant execute on function public.v2_captain_open_party_conversation(uuid,uuid,text,text,uuid) to authenticated;

notify pgrst,'reload schema';
