create unique index if not exists notifications_one_t24_operator_email_per_journey
on pace_v2.notifications(operator_id,departure_id,template_code)
where channel='email' and template_code='T24_OPERATOR_CONFIRMED_EMAIL';

create or replace function pace_v2.queue_t24_operator_confirmation_email(
  p_operator_id uuid,
  p_departure_id uuid,
  p_scheduled_at timestamptz default now()
) returns void
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_operator pace_v2.operators%rowtype;
  v_departure pace_v2.departures%rowtype;
  v_pickup text;
  v_destination text;
  v_return_departure pace_v2.departures%rowtype;
  v_return_pickup text;
  v_return_destination text;
  v_vehicles jsonb;
  v_parties jsonb;
  v_missing text[]:='{}'::text[];
  v_metadata jsonb;
begin
  select * into v_operator from pace_v2.operators where id=p_operator_id and active;
  select departure.* into v_departure from pace_v2.departures departure where departure.id=p_departure_id;
  select pickup.name,destination.name into v_pickup,v_destination
  from pace_v2.routes route
  join pace_v2.pickup_points pickup on pickup.id=route.pickup_id
  join pace_v2.destinations destination on destination.id=route.destination_id
  where route.id=v_departure.route_id;
  select return_leg.* into v_return_departure
  from pace_v2.journey_pairs pair
  join pace_v2.departures return_leg on return_leg.id=pair.return_departure_id
  where pair.outbound_departure_id=p_departure_id;
  select pickup.name,destination.name into v_return_pickup,v_return_destination
  from pace_v2.routes route
  join pace_v2.pickup_points pickup on pickup.id=route.pickup_id
  join pace_v2.destinations destination on destination.id=route.destination_id
  where route.id=v_return_departure.route_id;

  select jsonb_agg(jsonb_build_object(
    'vehicleType',resource.vehicle_type,'vehicleName',resource.vehicle_name,'captainName',resource.captain_name
  ) order by resource.vehicle_name) into v_vehicles
  from (
    select distinct vehicle_type.name as vehicle_type,vehicle.name as vehicle_name,
      concat_ws(' ',captain.first_name,captain.last_name) as captain_name
    from pace_v2.confirmed_allocations allocation
    join pace_v2.vehicles vehicle on vehicle.id=allocation.vehicle_id and vehicle.active
    join pace_v2.vehicle_types vehicle_type on vehicle_type.id=vehicle.vehicle_type_id and vehicle_type.active
    left join pace_v2.captain_assignments assignment on assignment.confirmed_allocation_id=allocation.id and assignment.active
    left join pace_v2.captains captain on captain.id=assignment.captain_id and captain.active and captain.operator_id=allocation.operator_id
    where allocation.departure_id=p_departure_id and allocation.operator_id=p_operator_id and allocation.status='confirmed'
  ) resource;

  select jsonb_agg(jsonb_build_object(
    'party',party.party_name,'vehicleName',party.vehicle_name,'passengers',party.passengers
  ) order by party.party_name) into v_parties
  from (
    select booking.id,
      coalesce(nullif(trim(booking.customer_name),''),nullif(trim(booking.lead_last_name),'')||' party','Booking '||left(booking.id::text,8)) as party_name,
      vehicle.name as vehicle_name,
      jsonb_agg(jsonb_build_object('name',concat_ws(' ',passenger.first_name,passenger.last_name),'age_group',passenger.age_group,'category',passenger.age_group) order by passenger.created_at,passenger.id) as passengers
    from pace_v2.confirmed_allocations allocation
    join pace_v2.booking_allocations booking_allocation on booking_allocation.vehicle_consideration_id=allocation.consideration_id
    join pace_v2.bookings booking on booking.id=booking_allocation.booking_id
    join pace_v2.vehicles vehicle on vehicle.id=allocation.vehicle_id
    join pace_v2.passengers passenger on passenger.booking_id=booking.id
    where allocation.departure_id=p_departure_id
      and allocation.operator_id=p_operator_id
      and allocation.status='confirmed'
      and pace_v2.is_active_paid_journey_booking(booking.id,null)
    group by booking.id,booking.customer_name,booking.lead_last_name,vehicle.name
  ) party;

  if v_operator.id is null then v_missing:=array_append(v_missing,'active operator'); end if;
  if not pace_v2.is_valid_customer_notification_email(coalesce(nullif(trim(v_operator.notification_email),''),nullif(trim(v_operator.contact_email),''),nullif(trim(v_operator.admin_email),''),nullif(trim(v_operator.email),''))) then v_missing:=array_append(v_missing,'valid operator email'); end if;
  if v_departure.id is null or v_pickup is null or v_destination is null then v_missing:=array_append(v_missing,'outbound itinerary'); end if;
  if v_return_departure.id is null or v_return_pickup is null or v_return_destination is null then v_missing:=array_append(v_missing,'return itinerary'); end if;
  if coalesce(jsonb_array_length(v_vehicles),0)=0 then v_missing:=array_append(v_missing,'scheduled vehicle'); end if;
  if exists(select 1 from jsonb_array_elements(coalesce(v_vehicles,'[]'::jsonb)) item where nullif(trim(item->>'captainName'),'') is null) then v_missing:=array_append(v_missing,'assigned captain'); end if;
  if coalesce(jsonb_array_length(v_parties),0)=0 then v_missing:=array_append(v_missing,'passenger manifest'); end if;
  if exists(select 1 from jsonb_array_elements(coalesce(v_parties,'[]'::jsonb)) party cross join jsonb_array_elements(party->'passengers') passenger where nullif(trim(passenger->>'name'),'') is null or passenger->>'age_group' not in ('adult','child','infant')) then v_missing:=array_append(v_missing,'complete passenger names and age groups'); end if;

  if cardinality(v_missing)>0 then
    insert into pace_v2.operational_alerts(exception_key,exception_type,severity,departure_id,details)
    values('t24_operator_email_incomplete:'||p_operator_id::text||':'||p_departure_id::text,'t24_operator_email_incomplete','high',p_departure_id,jsonb_build_object('operator_id',p_operator_id,'missing',v_missing))
    on conflict (exception_key) where resolved_at is null do update set detected_at=excluded.detected_at,severity='high',details=excluded.details;
    return;
  end if;

  v_metadata:=jsonb_build_object(
    'pickupName',v_pickup,'destinationName',v_destination,
    'departureDate',to_char(v_departure.scheduled_departure_ts at time zone v_departure.trip_timezone,'FMDay, FMDD FMMonth YYYY'),
    'vehicles',v_vehicles,
    'itinerary',jsonb_build_array(
      jsonb_build_object('journey','Journey 1','route',v_pickup||' to '||v_destination,'pickupTime',to_char(v_departure.scheduled_departure_ts at time zone v_departure.trip_timezone,'FMHH12:MI AM'),'arriveByTime',to_char((v_departure.scheduled_departure_ts-interval '15 minutes') at time zone v_departure.trip_timezone,'FMHH12:MI AM')),
      jsonb_build_object('journey','Journey 2','route',v_return_pickup||' to '||v_return_destination,'pickupTime',to_char(v_return_departure.scheduled_departure_ts at time zone v_return_departure.trip_timezone,'FMHH12:MI AM'),'arriveByTime',to_char((v_return_departure.scheduled_departure_ts-interval '15 minutes') at time zone v_return_departure.trip_timezone,'FMHH12:MI AM'))
    ),
    'parties',v_parties
  );
  insert into pace_v2.notifications(operator_id,departure_id,channel,to_email,template_code,subject,body,status,scheduled_at,metadata)
  values(p_operator_id,p_departure_id,'email',coalesce(nullif(trim(v_operator.notification_email),''),nullif(trim(v_operator.contact_email),''),nullif(trim(v_operator.admin_email),''),nullif(trim(v_operator.email),'')),'T24_OPERATOR_CONFIRMED_EMAIL','Journey confirmed for '||v_pickup||' to '||v_destination||' tomorrow','Your confirmed journey, resources, itinerary and manifest are attached.','queued',least(coalesce(p_scheduled_at,now()),now()),v_metadata)
  on conflict do nothing;
end;
$function$;

create or replace function pace_v2.queue_t24_operator_email_from_notification()
returns trigger
language plpgsql
security definer
set search_path=''
as $trigger$
begin
  if new.template_code='T24_OPERATOR_CONFIRMED' and new.channel='in_app' and new.operator_id is not null and new.departure_id is not null then
    perform pace_v2.queue_t24_operator_confirmation_email(new.operator_id,new.departure_id,new.scheduled_at);
  end if;
  return new;
end;
$trigger$;

drop trigger if exists notifications_queue_t24_operator_email on pace_v2.notifications;
create trigger notifications_queue_t24_operator_email
after insert on pace_v2.notifications
for each row execute function pace_v2.queue_t24_operator_email_from_notification();

revoke all on function pace_v2.queue_t24_operator_confirmation_email(uuid,uuid,timestamptz),pace_v2.queue_t24_operator_email_from_notification() from public,anon,authenticated;

do $backfill$
declare item record;
begin
  for item in
    select distinct notification.operator_id,notification.departure_id,notification.scheduled_at
    from pace_v2.notifications notification
    join pace_v2.departures departure on departure.id=notification.departure_id
    where notification.template_code='T24_OPERATOR_CONFIRMED' and notification.channel='in_app'
      and notification.operator_id is not null and departure.scheduled_departure_ts>now()
      and departure.status not in ('cancelled','completed')
  loop
    perform pace_v2.queue_t24_operator_confirmation_email(item.operator_id,item.departure_id,item.scheduled_at);
  end loop;
end;
$backfill$;
