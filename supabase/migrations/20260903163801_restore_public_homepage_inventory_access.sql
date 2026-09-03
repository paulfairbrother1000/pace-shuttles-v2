-- Keep the internal vehicle-offer eligibility helper unavailable to API
-- roles. The public wrapper exposes only the established departure catalogue
-- columns used by the customer homepage.
create or replace function public.v2_public_departure_inventory()
returns table(
  departure_id uuid,
  route_id uuid,
  route_name text,
  country_id uuid,
  pickup_id uuid,
  destination_id uuid,
  approx_duration_mins integer,
  trip_timezone text,
  route_picture_url text,
  display_description text,
  scheduled_departure_ts timestamptz,
  scheduled_arrival_ts timestamptz,
  local_departure_date date,
  status pace_v2.departure_status,
  t72_ts timestamptz,
  t24_ts timestamptz,
  pickup_name text,
  pickup_picture_url text,
  pickup_description text,
  destination_name text,
  destination_picture_url text,
  destination_description text,
  wet_or_dry text,
  vehicle_types jsonb
)
language sql
stable
security definer
set search_path = ''
as $$
  with eligible as (
    select
      departure.id as departure_id,
      offer.vehicle_type_id
    from pace_v2.departures departure
    join pace_v2.routes route
      on route.id = departure.route_id
     and route.is_active
    join pace_v2.countries country
      on country.id = route.country_id
     and country.active
     and country.customer_availability_paused is not true
    join pace_v2.destinations destination
      on destination.id = route.destination_id
     and destination.active
     and destination.published_at is not null
    cross join lateral pace_v2.get_eligible_vehicle_offers(departure.id) offer
    where departure.is_commercial
      and departure.scheduled_departure_ts > now()
      and departure.status in (
        'scheduled',
        'selling',
        'at_risk',
        'under_consideration'
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
      on vehicle_type.id = eligible.vehicle_type_id
     and vehicle_type.active
    group by eligible.departure_id
  )
  select
    departure.id,
    departure.route_id,
    route.route_name,
    route.country_id,
    route.pickup_id,
    route.destination_id,
    route.approx_duration_mins,
    route.trip_timezone,
    route.picture_url,
    route.display_description,
    departure.scheduled_departure_ts,
    departure.scheduled_arrival_ts,
    departure.local_departure_date,
    departure.status,
    departure.t72_ts,
    departure.t24_ts,
    pickup.name,
    pickup.picture_url,
    pickup.description,
    destination.name,
    destination.picture_url,
    destination.description,
    destination.wet_or_dry,
    vehicle_type_catalogue.vehicle_types
  from vehicle_type_catalogue
  join pace_v2.departures departure
    on departure.id = vehicle_type_catalogue.departure_id
  join pace_v2.routes route
    on route.id = departure.route_id
  join pace_v2.pickup_points pickup
    on pickup.id = route.pickup_id
   and pickup.active
  join pace_v2.destinations destination
    on destination.id = route.destination_id
   and destination.active
   and destination.published_at is not null;
$$;

revoke all on function public.v2_public_departure_inventory()
from public, anon, authenticated;
grant execute on function public.v2_public_departure_inventory()
to anon, authenticated;

create or replace view public.v2_public_departures as
select * from public.v2_public_departure_inventory();

grant select on public.v2_public_departures to anon, authenticated;

notify pgrst, 'reload schema';
