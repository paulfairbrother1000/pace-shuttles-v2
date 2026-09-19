-- Customer-to-captain contact is available from T-24 until local midnight
-- after the final scheduled journey leg. The same helper protects both the
-- customer UI projection and the write RPCs.
create or replace function pace_v2.journey_message_closes_at(p_confirmed_allocation_id uuid)
returns timestamptz
language sql
stable
security definer
set search_path=''
as $$
  select (
    coalesce(return_leg.local_departure_date,outbound.local_departure_date)+1
  )::timestamp at time zone coalesce(
    nullif(return_leg.trip_timezone,''),
    nullif(outbound.trip_timezone,''),
    'UTC'
  )
  from pace_v2.confirmed_allocations allocation
  join pace_v2.departures outbound on outbound.id=allocation.departure_id
  left join pace_v2.journey_pairs pair on pair.outbound_departure_id=outbound.id
  left join pace_v2.departures return_leg on return_leg.id=pair.return_departure_id
  where allocation.id=p_confirmed_allocation_id
$$;

revoke all on function pace_v2.journey_message_closes_at(uuid) from public,anon,authenticated;

-- Paired bookings receive a full return itinerary. One-way bookings retain
-- the established reminder until a separate one-way copy change is approved.
create or replace function public.v2_system_schedule_t24_journey_notifications(p_as_of timestamptz)
returns integer
language plpgsql
security definer
set search_path=pace_v2,public
as $t24$
declare
  v_row record;
  v_missing text[];
  v_due_at timestamptz;
  v_minutes_late integer;
  v_queued integer:=0;
  v_subject text;
  v_body text;
  v_metadata jsonb;
begin
  for v_row in
    select
      b.id as booking_id,
      b.seats,
      ca.id as confirmed_allocation_id,
      cvt.id as captain_vehicle_type_id,
      d.id as departure_id,
      d.scheduled_departure_ts,
      d.trip_timezone as outbound_timezone,
      c.name as country_name,
      c.timezone,
      pp.name as pickup_name,
      pp.directions_url as pickup_directions_url,
      dst.name as destination_name,
      dst.wet_or_dry,
      v.name as vehicle_name,
      vt.name as vehicle_type,
      nullif(trim(coalesce(to_jsonb(cap)->>'first_name','')),'') as captain_first_name,
      nullif(trim(coalesce(to_jsonb(cap)->>'last_name','')),'') as captain_last_name,
      split_part(nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),''),' ',1) as first_name,
      nullif(trim(u.email),'') as to_email,
      pair.id as journey_pair_id,
      return_leg.id as return_departure_id,
      return_leg.scheduled_departure_ts as return_scheduled_departure_ts,
      return_leg.trip_timezone as return_timezone,
      coalesce(party.adult_count,0)::integer as adult_count,
      coalesce(party.child_count,0)::integer as child_count,
      coalesce(party.infant_count,0)::integer as infant_count
    from pace_v2.bookings b
    join pace_v2.orders o on o.id=b.order_id
    left join pace_v2.booking_allocations ba on ba.booking_id=b.id
    left join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status='confirmed'
    join pace_v2.departures d on d.id=coalesce(ca.departure_id,nullif(to_jsonb(b)->>'departure_id','')::uuid) and d.status not in ('cancelled','completed')
    join pace_v2.routes r on r.id=d.route_id
    join pace_v2.countries c on c.id=r.country_id
    join pace_v2.pickup_points pp on pp.id=r.pickup_id
    join pace_v2.destinations dst on dst.id=r.destination_id
    left join pace_v2.journey_pairs pair on pair.outbound_departure_id=d.id
    left join pace_v2.departures return_leg on return_leg.id=pair.return_departure_id
    left join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
    left join pace_v2.vehicle_types vt on vt.id=v.vehicle_type_id
    left join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
    left join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id
    left join pace_v2.captain_vehicle_types cvt on cvt.captain_id=cap.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
    left join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id)
    left join lateral (
      select
        count(*) filter (where coalesce(p.age_group,'adult')='adult') as adult_count,
        count(*) filter (where p.age_group='child') as child_count,
        count(*) filter (where p.age_group='infant') as infant_count
      from pace_v2.passengers p
      where p.booking_id=b.id
    ) party on true
    where p_as_of>=d.scheduled_departure_ts-interval '24 hours'
      and p_as_of<d.scheduled_departure_ts
      and lower(coalesce(to_jsonb(o)->>'payment_status',to_jsonb(o)->>'status','')) in ('paid','succeeded','complete','completed')
      and lower(coalesce(to_jsonb(b)->>'status','active')) not in ('cancelled','canceled','refunded','inactive')
      and (
        ca.id is not null
        or not exists(
          select 1
          from pace_v2.booking_allocations confirmed_booking_allocation
          join pace_v2.confirmed_allocations confirmed_allocation
            on confirmed_allocation.consideration_id=confirmed_booking_allocation.vehicle_consideration_id
           and confirmed_allocation.status='confirmed'
          where confirmed_booking_allocation.booking_id=b.id
        )
      )
  loop
    v_due_at:=v_row.scheduled_departure_ts-interval '24 hours';
    v_missing:='{}'::text[];
    if v_row.confirmed_allocation_id is null then v_missing:=array_append(v_missing,'confirmed vehicle allocation'); end if;
    if nullif(trim(coalesce(v_row.to_email,'')),'') is null then v_missing:=array_append(v_missing,'customer email'); end if;
    if v_row.journey_pair_id is null and not pace_v2.is_valid_t24_directions_url(v_row.pickup_directions_url) then v_missing:=array_append(v_missing,'valid pickup directions'); end if;
    if nullif(trim(coalesce(v_row.outbound_timezone,v_row.timezone,'')),'') is null then v_missing:=array_append(v_missing,'journey timezone'); end if;
    if nullif(trim(coalesce(v_row.first_name,'')),'') is null then v_missing:=array_append(v_missing,'party leader first name'); end if;
    if v_row.captain_vehicle_type_id is null then v_missing:=array_append(v_missing,'eligible captain assignment'); end if;
    if v_row.captain_first_name is null then v_missing:=array_append(v_missing,'missing captain first name'); end if;
    if v_row.captain_last_name is null then v_missing:=array_append(v_missing,'missing captain last name'); end if;
    if nullif(trim(coalesce(v_row.vehicle_name,'')),'') is null or nullif(trim(coalesce(v_row.vehicle_type,'')),'') is null then v_missing:=array_append(v_missing,'confirmed vehicle details'); end if;

    if v_row.journey_pair_id is not null then
      if v_row.return_departure_id is null or v_row.return_scheduled_departure_ts is null then v_missing:=array_append(v_missing,'complete return journey schedule'); end if;
      if nullif(trim(coalesce(v_row.return_timezone,'')),'') is null then v_missing:=array_append(v_missing,'return journey timezone'); end if;
      if v_row.adult_count+v_row.child_count+v_row.infant_count<>v_row.seats then v_missing:=array_append(v_missing,'complete passenger age groups'); end if;
      if nullif(trim(coalesce(v_row.country_name,'')),'') is null then v_missing:=array_append(v_missing,'country name'); end if;
    end if;

    if cardinality(v_missing)>0 then
      insert into pace_v2.operational_alerts(exception_key,exception_type,severity,confirmed_allocation_id,booking_id,departure_id,details)
      values(
        't24_details_overdue:'||v_row.booking_id::text,
        't24_details_overdue',
        'high',
        v_row.confirmed_allocation_id,
        v_row.booking_id,
        v_row.departure_id,
        jsonb_build_object('missing',v_missing,'due_at',v_due_at,'as_of',p_as_of)
      )
      on conflict (exception_key) where resolved_at is null do update
        set severity='high',details=excluded.details,detected_at=excluded.detected_at;
      continue;
    end if;

    v_minutes_late:=greatest(0,floor(extract(epoch from p_as_of-v_due_at)/60)::integer);

    if v_row.journey_pair_id is not null then
      v_subject:='Reminder of Itinerary for '||v_row.pickup_name||' to '||v_row.destination_name||' tomorrow';
      v_body:=
        'Hi '||v_row.first_name||E'\n\nYour Pace Shuttles return journey in '||v_row.country_name||' between '||v_row.pickup_name||' and '||v_row.destination_name||E' is almost upon us.\n\nYour '||v_row.vehicle_type||E' and captain have now been assigned to your trip.\n\n'||
        v_row.vehicle_type||E':\n'||v_row.vehicle_name||E'\n\nCaptain: '||v_row.captain_first_name||' '||v_row.captain_last_name||E'\n\nHere is a reminder of your itinerary details.\n\nParty of '||
        v_row.adult_count||' '||case when v_row.adult_count=1 then 'adult' else 'adults' end||', '||
        v_row.child_count||' '||case when v_row.child_count=1 then 'child' else 'children' end||' and '||
        v_row.infant_count||' '||case when v_row.infant_count=1 then 'infant' else 'infants' end||E'\n\nJourney 1: '||v_row.pickup_name||' to '||v_row.destination_name||E'\n\nPick up time: '||
        to_char(v_row.scheduled_departure_ts at time zone coalesce(nullif(v_row.outbound_timezone,''),v_row.timezone),'FMHH12:MI AM')||E'\n\nPlease be at the '||v_row.vehicle_type||' by '||
        to_char((v_row.scheduled_departure_ts-interval '15 minutes') at time zone coalesce(nullif(v_row.outbound_timezone,''),v_row.timezone),'FMHH12:MI AM')||E'\n\nJourney 2: '||v_row.destination_name||' to '||v_row.pickup_name||E'\n\nPick up time: '||
        to_char(v_row.return_scheduled_departure_ts at time zone v_row.return_timezone,'FMHH12:MI AM')||E'\n\nPlease be at the '||v_row.vehicle_type||' by '||
        to_char((v_row.return_scheduled_departure_ts-interval '15 minutes') at time zone v_row.return_timezone,'FMHH12:MI AM')||
        case when v_row.wet_or_dry='wet' then E'\n\n'||v_row.destination_name||E' is a wet arrival destination, meaning you and your party will get wet. Please make sure you have appropriate clothes and a towel with this in mind.' else '' end||
        E'\n\nContacting Us\n\nOn the day of the journey, you can contact Captain '||v_row.captain_last_name||E' if necessary using My Journeys > Help & Support > Contact the Captain in the Pace Shuttles portal.\n\nWe hope you have a great return trip to '||v_row.destination_name||' with Captain '||v_row.captain_last_name||' onboard '||v_row.vehicle_name||E'.\n\nBon voyage!\n\nThe Pace Shuttles Team';
      v_metadata:=jsonb_build_object(
        'first_name',v_row.first_name,
        'country_name',v_row.country_name,
        'pickup_name',v_row.pickup_name,
        'destination_name',v_row.destination_name,
        'outbound_pickup_time_label',to_char(v_row.scheduled_departure_ts at time zone coalesce(nullif(v_row.outbound_timezone,''),v_row.timezone),'FMHH12:MI AM'),
        'outbound_arrival_by_time_label',to_char((v_row.scheduled_departure_ts-interval '15 minutes') at time zone coalesce(nullif(v_row.outbound_timezone,''),v_row.timezone),'FMHH12:MI AM'),
        'return_pickup_time_label',to_char(v_row.return_scheduled_departure_ts at time zone v_row.return_timezone,'FMHH12:MI AM'),
        'return_arrival_by_time_label',to_char((v_row.return_scheduled_departure_ts-interval '15 minutes') at time zone v_row.return_timezone,'FMHH12:MI AM'),
        'adult_count',v_row.adult_count,
        'child_count',v_row.child_count,
        'infant_count',v_row.infant_count,
        'captain_full_name',v_row.captain_first_name||' '||v_row.captain_last_name,
        'captain_surname',v_row.captain_last_name,
        'vehicle_type',v_row.vehicle_type,
        'vehicle_name',v_row.vehicle_name,
        'wet_destination',v_row.wet_or_dry='wet',
        'minutes_late',v_minutes_late,
        'scheduled_t24_at',v_due_at
      );
    else
      v_subject:='Your Journey to '||v_row.destination_name||' is Tomorrow!';
      v_body:='Hi '||v_row.first_name||E',\n\nThe time is almost upon us!'||E'\n\nYour journey from '||v_row.pickup_name||' to '||v_row.destination_name||' at '||to_char(v_row.scheduled_departure_ts at time zone v_row.timezone,'FMHH12:MI AM')||' is scheduled with Captain '||v_row.captain_first_name||' '||v_row.captain_last_name||' aboard the '||v_row.vehicle_type||' '||v_row.vehicle_name||'.'||E'\n\nPlease arrive at '||v_row.pickup_name||' no later than '||to_char((v_row.scheduled_departure_ts-interval '15 minutes') at time zone v_row.timezone,'FMHH12:MI AM')||'.'||E'\n\nGet directions to your pickup point\n'||v_row.pickup_directions_url||case when v_row.wet_or_dry='wet' then E'\n\nPlease prepare for a wet arrival\n\nThere is no mooring at '||v_row.destination_name||', so you will get wet when you disembark. Please bring a towel and any suitable clothing or footwear you may require.' else '' end||E'\n\nNeed to contact your captain on the day of travel?\n\nSign in to My Journeys (https://www.paceshuttles.com/customer), select this booking and open Help & Support. Choose Contact the Captain, write your message and select Contact captain.\n\nYour captain will receive the message through Pace Shuttles. This secure conversation will remain available until local midnight after your journey day.\n\nWe hope you have a wonderful journey to '||v_row.destination_name||' with Captain '||v_row.captain_last_name||E'.\n\nRegards,\nThe Pace Shuttles Team';
      v_metadata:=jsonb_build_object('minutes_late',v_minutes_late,'scheduled_t24_at',v_due_at);
    end if;

    insert into pace_v2.notifications(booking_id,departure_id,to_email,template_code,subject,body,status,scheduled_at,metadata)
    values(v_row.booking_id,v_row.departure_id,v_row.to_email,'journey_tomorrow',v_subject,v_body,'queued',p_as_of,v_metadata)
    on conflict (booking_id,template_code) where template_code='journey_tomorrow' do nothing;
    if found then v_queued:=v_queued+1; end if;

    update pace_v2.operational_alerts
    set resolved_at=now(),resolution_note='T-24 details corrected; reminder queued'
    where exception_key='t24_details_overdue:'||v_row.booking_id::text
      and resolved_at is null;
  end loop;

  v_queued:=v_queued+pace_v2.queue_captain_pending_t24_notifications(p_as_of);
  return v_queued;
end;
$t24$;

revoke all on function public.v2_system_schedule_t24_journey_notifications(timestamptz) from public,anon,authenticated;
grant execute on function public.v2_system_schedule_t24_journey_notifications(timestamptz) to service_role;
