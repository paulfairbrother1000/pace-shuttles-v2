alter table pace_v2.services
  add column if not exists schedule_enforced boolean not null default false;

create or replace function public.v2_admin_save_service_schedule(
  p_service_id uuid,
  p_days_of_week smallint[],
  p_departure_time time,
  p_valid_from date,
  p_valid_to date,
  p_recurrence_type text default 'weekly',
  p_recurrence_interval_weeks integer default 1,
  p_recurrence_anchor_date date default null
) returns void
language plpgsql security definer set search_path='public','pace_v2','auth' as $$
declare
  v_service pace_v2.services%rowtype;
  v_schedule_changed boolean;
begin
  if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
  if p_service_id is null or p_days_of_week is null or cardinality(p_days_of_week)=0
     or exists(select 1 from unnest(p_days_of_week) day where day<0 or day>6)
     or p_departure_time is null or p_valid_from is null
     or (p_valid_to is not null and p_valid_to<p_valid_from)
     or coalesce(p_recurrence_interval_weeks,1)<1 then
    raise exception using errcode='22023',message='valid weekly days, departure time, season dates, and recurrence are required';
  end if;
  select * into v_service from pace_v2.services where id=p_service_id for update;
  if v_service.id is null then raise exception 'service not found'; end if;
  if not exists(select 1 from pg_timezone_names where name=v_service.timezone) then
    raise exception using errcode='22023',message='service timezone is invalid';
  end if;
  v_schedule_changed:=v_service.days_of_week is distinct from p_days_of_week
    or v_service.departure_time is distinct from p_departure_time
    or v_service.valid_from is distinct from p_valid_from
    or v_service.valid_to is distinct from p_valid_to
    or v_service.recurrence_type is distinct from coalesce(nullif(trim(p_recurrence_type),''),'weekly')
    or v_service.recurrence_interval_weeks is distinct from coalesce(p_recurrence_interval_weeks,1)
    or v_service.recurrence_anchor_date is distinct from coalesce(p_recurrence_anchor_date,p_valid_from);
  if v_schedule_changed and exists(
    select 1 from pace_v2.departures d
    where d.service_id=p_service_id and d.is_commercial and d.scheduled_departure_ts>now()
      and (
        exists(select 1 from pace_v2.bookings b where b.departure_id=d.id)
        or exists(select 1 from pace_v2.confirmed_allocations a where a.departure_id=d.id)
        or exists(select 1 from pace_v2.booking_allocations ba join pace_v2.vehicle_considerations vc on vc.id=ba.vehicle_consideration_id where vc.departure_id=d.id)
        or exists(select 1 from pace_v2.captain_leg_operations op where op.departure_id=d.id)
        or exists(select 1 from pace_v2.quote_intents qi where qi.departure_id=d.id and qi.expires_at>now())
        or d.actual_departure_ts is not null or d.actual_arrival_ts is not null or d.status<>'scheduled'
      )
  ) then
    raise exception using errcode='22023',message='schedule cannot change while future journeys have bookings, allocations, active quotes, or operation evidence';
  end if;
  update pace_v2.services
  set days_of_week=p_days_of_week,
      departure_time=p_departure_time,
      valid_from=p_valid_from,
      valid_to=p_valid_to,
      recurrence_type=coalesce(nullif(trim(p_recurrence_type),''),'weekly'),
      recurrence_interval_weeks=coalesce(p_recurrence_interval_weeks,1),
      recurrence_anchor_date=coalesce(p_recurrence_anchor_date,p_valid_from),
      schedule_enforced=true,
      updated_at=now()
  where id=p_service_id;
end $$;

revoke all on function public.v2_admin_save_service_schedule(uuid,smallint[],time,date,date,text,integer,date) from public,anon;
grant execute on function public.v2_admin_save_service_schedule(uuid,smallint[],time,date,date,text,integer,date) to authenticated;

-- Restore the four-week customer search window that the captain migration
-- accidentally removed. Generated departures extend for a year; evaluating
-- paired vehicle/captain eligibility for all of them exceeds the API timeout.
create or replace function pace_v2.public_departure_inventory()
returns table(
  departure_id uuid, route_id uuid, route_name text, country_id uuid,
  pickup_id uuid, destination_id uuid, approx_duration_mins integer,
  trip_timezone text, route_picture_url text, display_description text,
  scheduled_departure_ts timestamptz, scheduled_arrival_ts timestamptz,
  local_departure_date date, status pace_v2.departure_status,
  t72_ts timestamptz, t24_ts timestamptz, pickup_name text,
  pickup_picture_url text, pickup_description text, destination_name text,
  destination_picture_url text, destination_description text,
  wet_or_dry text, vehicle_types jsonb
)
language sql
stable
security definer
set search_path = ''
as $$
  with eligible as (
    select departure.id as departure_id, offer.vehicle_type_id
    from pace_v2.departures departure
    join pace_v2.routes route
      on route.id = departure.route_id and route.is_active
    join pace_v2.countries country
      on country.id = route.country_id
     and country.active
     and country.customer_availability_paused is not true
    join pace_v2.destinations destination
      on destination.id = route.destination_id
     and destination.active
     and destination.published_at is not null
    left join pace_v2.services service on service.id=departure.service_id
    cross join lateral pace_v2.get_eligible_vehicle_offers(departure.id) offer
    where departure.is_commercial
      and departure.scheduled_departure_ts > now()
      and departure.scheduled_departure_ts <= now() + interval '28 days'
      and departure.status in (
        'scheduled', 'selling', 'at_risk', 'under_consideration'
      )
      and (
        departure.service_id is null
        or service.schedule_enforced is not true
        or pace_v2.is_qualified_service_departure(service.id,departure.id,service.departure_time)
      )
    group by departure.id, offer.vehicle_type_id
  ), vehicle_type_catalogue as (
    select
      eligible.departure_id,
      jsonb_agg(
        jsonb_build_object(
          'id', vehicle_type.id,
          'name', vehicle_type.name,
          'picture_url', vehicle_type.picture_url
        ) order by vehicle_type.name
      ) as vehicle_types
    from eligible
    join pace_v2.vehicle_types vehicle_type
      on vehicle_type.id = eligible.vehicle_type_id and vehicle_type.active
    group by eligible.departure_id
  )
  select
    departure.id, departure.route_id, route.route_name, route.country_id,
    route.pickup_id, route.destination_id, route.approx_duration_mins,
    route.trip_timezone, route.picture_url, route.display_description,
    departure.scheduled_departure_ts, departure.scheduled_arrival_ts,
    departure.local_departure_date, departure.status, departure.t72_ts,
    departure.t24_ts, pickup.name, pickup.picture_url, pickup.description,
    destination.name, destination.picture_url, destination.description,
    destination.wet_or_dry, vehicle_type_catalogue.vehicle_types
  from vehicle_type_catalogue
  join pace_v2.departures departure
    on departure.id = vehicle_type_catalogue.departure_id
  join pace_v2.routes route on route.id = departure.route_id
  join pace_v2.pickup_points pickup
    on pickup.id = route.pickup_id and pickup.active
  join pace_v2.destinations destination
    on destination.id = route.destination_id
   and destination.active
   and destination.published_at is not null;
$$;


