-- Queue one detailed email per operator and journey when the existing T-72
-- in-app notification is created. The email renderer consumes the structured
-- metadata so content and HTML presentation remain testable in application code.

create unique index if not exists notifications_one_t72_operator_email_per_source
on pace_v2.notifications ((metadata->>'sourceNotificationId'))
where channel='email'
  and template_code='T72_UNDER_CONSIDERATION'
  and metadata ? 'sourceNotificationId';

create or replace function pace_v2.queue_informative_t72_operator_email()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_email text;
  v_journey_name text;
  v_departure_date text;
  v_departure_time text;
  v_t24_date text;
  v_t24_time text;
  v_vehicles jsonb;
  v_metadata jsonb;
begin
  if new.channel<>'in_app'
     or new.template_code<>'T72_UNDER_CONSIDERATION'
     or new.operator_id is null
     or new.departure_id is null then
    return new;
  end if;

  select
    coalesce(
      nullif(trim(operator.notification_email),''),
      nullif(trim(operator.contact_email),''),
      nullif(trim(operator.admin_email),''),
      nullif(trim(operator.email),'')
    ),
    coalesce(nullif(trim(route.route_name),''),nullif(trim(route.name),'')),
    to_char(
      departure.scheduled_departure_ts at time zone coalesce(nullif(departure.trip_timezone,''),'UTC'),
      'FMDay, FMDD FMMonth YYYY'
    ),
    to_char(
      departure.scheduled_departure_ts at time zone coalesce(nullif(departure.trip_timezone,''),'UTC'),
      'FMHH12:MI am'
    ),
    to_char(
      departure.t24_ts at time zone coalesce(nullif(departure.trip_timezone,''),'UTC'),
      'FMDay, FMDD FMMonth YYYY'
    ),
    to_char(
      departure.t24_ts at time zone coalesce(nullif(departure.trip_timezone,''),'UTC'),
      'FMHH12:MI am'
    )
  into
    v_email,v_journey_name,v_departure_date,v_departure_time,v_t24_date,v_t24_time
  from pace_v2.departures departure
  join pace_v2.routes route on route.id=departure.route_id
  join pace_v2.operators operator
    on operator.id=new.operator_id and operator.active
  where departure.id=new.departure_id;

  if not found or not pace_v2.is_valid_customer_notification_email(v_email) then
    return new;
  end if;

  select jsonb_agg(
    jsonb_build_object(
      'vehicleType',resource.vehicle_type,
      'vehicleName',resource.vehicle_name,
      'captainName',resource.captain_name
    ) order by resource.vehicle_name,resource.vehicle_id
  )
  into v_vehicles
  from (
    select distinct
      vehicle.id as vehicle_id,
      vehicle.name as vehicle_name,
      vehicle_type.name as vehicle_type,
      captain_choice.captain_name
    from pace_v2.vehicle_considerations consideration
    join pace_v2.vehicles vehicle on vehicle.id=consideration.vehicle_id
    join pace_v2.vehicle_types vehicle_type on vehicle_type.id=vehicle.vehicle_type_id
    left join pace_v2.vehicle_route_offers route_offer
      on route_offer.id=consideration.vehicle_route_offer_id
    left join lateral (
      select concat_ws(' ',captain.first_name,captain.last_name) as captain_name
      from (
        select route_offer.preferred_captain_id as captain_id,0 as priority
        where route_offer.preferred_captain_id is not null
        union all
        select preference.captain_id,100+preference.priority
        from pace_v2.vehicle_captain_preferences preference
        where route_offer.preferred_captain_id is null
          and preference.vehicle_id=vehicle.id
          and preference.operator_id=vehicle.operator_id
          and preference.active
      ) candidate
      join pace_v2.captains captain
        on captain.id=candidate.captain_id
       and captain.operator_id=vehicle.operator_id
       and captain.active
      join pace_v2.captain_vehicle_types eligibility
        on eligibility.captain_id=captain.id
       and eligibility.vehicle_type_id=vehicle.vehicle_type_id
       and eligibility.active
      order by candidate.priority,captain.id
      limit 1
    ) captain_choice on true
    where consideration.departure_id=new.departure_id
      and consideration.operator_id=new.operator_id
      and consideration.status='under_consideration'
      and captain_choice.captain_name is not null
  ) resource;

  if v_vehicles is null or jsonb_array_length(v_vehicles)=0 then
    return new;
  end if;

  v_metadata:=jsonb_build_object(
    'sourceNotificationId',new.id::text,
    'journeyName',v_journey_name,
    'departureDate',v_departure_date,
    'departureTime',v_departure_time,
    't24Date',v_t24_date,
    't24Time',v_t24_time,
    'operatorPortalUrl','https://www.paceshuttles.com/operator',
    'vehicles',v_vehicles
  );

  insert into pace_v2.notifications(
    operator_id,departure_id,channel,template_code,subject,body,
    status,to_email,scheduled_at,metadata
  ) values (
    new.operator_id,new.departure_id,'email','T72_UNDER_CONSIDERATION',
    'Journey under consideration',
    'Your under-consideration resources are ready to review in the Operator Portal.',
    'queued',v_email,new.scheduled_at,v_metadata
  )
  on conflict do nothing;

  return new;
end;
$$;

drop trigger if exists queue_informative_t72_operator_email_after_insert
  on pace_v2.notifications;
create trigger queue_informative_t72_operator_email_after_insert
after insert on pace_v2.notifications
for each row execute function pace_v2.queue_informative_t72_operator_email();

revoke all on function pace_v2.queue_informative_t72_operator_email()
from public,anon,authenticated,service_role;
