-- Create the route, permitted vehicle type and recurring seasonal service as
-- one transaction so a partially configured route is never advertised.
create or replace function public.v2_admin_create_scheduled_route(
  p_pickup_id uuid,
  p_destination_id uuid,
  p_vehicle_type_id uuid,
  p_trip_timezone text,
  p_approx_duration_mins integer,
  p_region_id uuid,
  p_locality_id uuid,
  p_booking_lead_time_hours integer,
  p_t72_hours integer,
  p_t24_hours integer,
  p_display_description text,
  p_days_of_week smallint[],
  p_departure_time time without time zone,
  p_valid_from date,
  p_valid_to date
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pace_v2', 'auth'
as $function$
declare
  v_route_id uuid;
  v_service_name text;
begin
  if not pace_v2.is_site_admin() then
    raise exception 'site admin required';
  end if;

  if p_days_of_week is null
     or cardinality(p_days_of_week)=0
     or not (p_days_of_week <@ array[0,1,2,3,4,5,6]::smallint[])
     or cardinality(p_days_of_week) <> (
       select count(distinct day_value) from unnest(p_days_of_week) day_value
     ) then
    raise exception 'select one or more unique weekdays';
  end if;

  if p_departure_time is null then
    raise exception 'departure time required';
  end if;
  if p_valid_from is null or p_valid_to is null or p_valid_to < p_valid_from then
    raise exception 'valid season start and end dates are required';
  end if;
  if p_approx_duration_mins is null or p_approx_duration_mins <= 0 then
    raise exception 'journey duration must be greater than zero';
  end if;

  v_route_id := public.v2_admin_create_route(
    p_pickup_id,
    p_destination_id,
    p_trip_timezone,
    p_approx_duration_mins,
    p_region_id,
    p_locality_id,
    p_display_description,
    p_booking_lead_time_hours,
    p_t72_hours,
    p_t24_hours
  );

  perform public.v2_admin_set_route_vehicle_type(v_route_id,p_vehicle_type_id,true);

  select route_name into v_service_name
  from pace_v2.routes
  where id=v_route_id;

  perform public.v2_admin_create_service(
    v_route_id,
    coalesce(v_service_name,'Scheduled service'),
    p_trip_timezone,
    p_days_of_week,
    p_departure_time,
    p_valid_from,
    p_valid_to,
    'weekly',
    1,
    p_valid_from,
    null
  );

  return v_route_id;
end
$function$;

revoke all on function public.v2_admin_create_scheduled_route(uuid,uuid,uuid,text,integer,uuid,uuid,integer,integer,integer,text,smallint[],time without time zone,date,date) from public,anon,authenticated;
grant execute on function public.v2_admin_create_scheduled_route(uuid,uuid,uuid,text,integer,uuid,uuid,integer,integer,integer,text,smallint[],time without time zone,date,date) to authenticated;
