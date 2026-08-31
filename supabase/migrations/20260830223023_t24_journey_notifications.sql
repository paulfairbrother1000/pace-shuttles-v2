-- Created for this repository's V2 schema. It intentionally uses only V2 tables.
alter table pace_v2.notifications add column if not exists metadata jsonb not null default '{}'::jsonb;
alter table pace_v2.notifications add column if not exists to_email text;
alter table pace_v2.notifications alter column channel set default 'email';
create unique index if not exists customer_notifications_one_journey_tomorrow_per_booking
  on pace_v2.notifications(booking_id,template_code)
  where template_code='journey_tomorrow';

create or replace function pace_v2.is_valid_t24_directions_url(p_url text)
returns boolean
language sql
immutable
set search_path = pace_v2, public
as $$
  select coalesce(p_url ~* '^https://(?:(?:www[.])?google[.]com/maps(?:/|$)|maps[.]google[.](?:com|co[.]uk|co[.]in|com[.]au|ca|de|fr|es|it|nl|co[.]nz|com[.]br|com[.]mx|com[.]ar|co[.]jp|co[.]kr|com[.]sg|com[.]tw|com[.]hk)(?:/|$)|maps[.]app[.]goo[.]gl/)[^[:space:]]*$',false);
$$;
revoke all on function pace_v2.is_valid_t24_directions_url(text) from public,anon,authenticated;

create or replace function public.v2_system_schedule_t24_journey_notifications(p_as_of timestamptz)
returns integer
language plpgsql
security definer
set search_path = pace_v2, public
as $t24$
declare
  v_row record;
  v_missing text[];
  v_due_at timestamptz;
  v_minutes_late integer;
  v_queued integer:=0;
begin
  for v_row in
    select
      b.id as booking_id, ca.id as confirmed_allocation_id, cvt.id as captain_vehicle_type_id, d.id as departure_id,
      d.scheduled_departure_ts, c.name as country_name, c.timezone,
      pp.name as pickup_name, pp.directions_url as pickup_directions_url,
      dst.name as destination_name, dst.wet_or_dry,
      v.name as vehicle_name, vt.name as vehicle_type,
      nullif(trim(coalesce(to_jsonb(cap)->>'first_name','')),'') as captain_first_name,
      nullif(trim(coalesce(to_jsonb(cap)->>'last_name','')),'') as captain_last_name,
      split_part(nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),''),' ',1) as first_name,
      nullif(trim(u.email),'') as to_email
    from pace_v2.bookings b
    join pace_v2.orders o on o.id=b.order_id
    left join pace_v2.booking_allocations ba on ba.booking_id=b.id
    left join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status='confirmed'
    join pace_v2.departures d on d.id=coalesce(ca.departure_id,nullif(to_jsonb(b)->>'departure_id','')::uuid) and d.status not in ('cancelled','completed')
    join pace_v2.routes r on r.id=d.route_id
    join pace_v2.countries c on c.id=r.country_id
    join pace_v2.pickup_points pp on pp.id=r.pickup_id
    join pace_v2.destinations dst on dst.id=r.destination_id
    left join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
    left join pace_v2.vehicle_types vt on vt.id=v.vehicle_type_id
    left join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
    left join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id
    left join pace_v2.captain_vehicle_types cvt on cvt.captain_id=cap.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
    left join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id)
    where p_as_of >= d.scheduled_departure_ts-interval '24 hours'
      and p_as_of < d.scheduled_departure_ts
      and lower(coalesce(to_jsonb(o)->>'payment_status',to_jsonb(o)->>'status','')) in ('paid','succeeded','complete','completed')
      and lower(coalesce(to_jsonb(b)->>'status','active')) not in ('cancelled','canceled','refunded','inactive')
  loop
    v_due_at:=v_row.scheduled_departure_ts-interval '24 hours';
    v_missing:='{}'::text[];
    if v_row.confirmed_allocation_id is null then v_missing:=array_append(v_missing,'confirmed vehicle allocation'); end if;
    if nullif(trim(coalesce(v_row.to_email,'')),'') is null then v_missing:=array_append(v_missing,'customer email'); end if;
    if not pace_v2.is_valid_t24_directions_url(v_row.pickup_directions_url) then v_missing:=array_append(v_missing,'valid pickup directions'); end if;
    if nullif(trim(coalesce(v_row.timezone,'')),'') is null then v_missing:=array_append(v_missing,'country timezone'); end if;
    if nullif(trim(coalesce(v_row.first_name,'')),'') is null then v_missing:=array_append(v_missing,'party leader first name'); end if;
    if v_row.captain_vehicle_type_id is null then v_missing:=array_append(v_missing,'eligible captain assignment'); end if;
    if v_row.captain_first_name is null then v_missing:=array_append(v_missing,'missing captain first name'); end if;
    if v_row.captain_last_name is null then v_missing:=array_append(v_missing,'missing captain last name'); end if;
    if nullif(trim(coalesce(v_row.vehicle_name,'')),'') is null or nullif(trim(coalesce(v_row.vehicle_type,'')),'') is null then v_missing:=array_append(v_missing,'confirmed vehicle details'); end if;

    if cardinality(v_missing)>0 then
      insert into pace_v2.operational_alerts(exception_key,exception_type,severity,confirmed_allocation_id,booking_id,departure_id,details)
      values('t24_details_overdue:'||v_row.booking_id::text,'t24_details_overdue','high',v_row.confirmed_allocation_id,v_row.booking_id,v_row.departure_id,
        jsonb_build_object('missing',v_missing,'due_at',v_due_at,'as_of',p_as_of))
      on conflict (exception_key) where resolved_at is null do update
        set severity='high',details=excluded.details,detected_at=excluded.detected_at;
      continue;
    end if;

    v_minutes_late:=greatest(0,floor(extract(epoch from p_as_of-v_due_at)/60)::integer);
    insert into pace_v2.notifications(booking_id,departure_id,to_email,template_code,subject,body,status,scheduled_at,metadata)
    select v_row.booking_id,v_row.departure_id,v_row.to_email,'journey_tomorrow',
      'Your Journey to '||v_row.destination_name||' is Tomorrow!',
      'Hi '||v_row.first_name||E',\n\nThe time is almost upon us!'||E'\n\nYour journey from '||v_row.pickup_name||' to '||v_row.destination_name||' at '||to_char(v_row.scheduled_departure_ts at time zone v_row.timezone,'FMHH12:MI AM')||' is scheduled with Captain '||v_row.captain_first_name||' '||v_row.captain_last_name||' aboard the '||v_row.vehicle_type||' '||v_row.vehicle_name||'.'||E'\n\nPlease arrive at '||v_row.pickup_name||' no later than '||to_char((v_row.scheduled_departure_ts-interval '15 minutes') at time zone v_row.timezone,'FMHH12:MI AM')||'.'||E'\n\nGet directions to your pickup point\n'||v_row.pickup_directions_url||case when v_row.wet_or_dry='wet' then E'\n\nPlease prepare for a wet arrival\n\nThere is no mooring at '||v_row.destination_name||', so you will get wet when you disembark. Please bring a towel and any suitable clothing or footwear you may require.' else '' end||E'\n\nNeed to contact your captain on the day of travel?\n\nSign in to My Journeys (https://www.paceshuttles.com/customer), select this booking and open Help & Support. Choose Day of Travel, write your message and select Contact captain.\n\nYour captain will receive the message through Pace Shuttles. This secure conversation will remain available until four hours after your journey is completed.\n\nWe hope you have a wonderful journey to '||v_row.destination_name||' with Captain '||v_row.captain_last_name||E'.\n\nRegards,\nThe Pace Shuttles Team',
      'queued',p_as_of,jsonb_build_object('minutes_late',v_minutes_late,'scheduled_t24_at',v_due_at)
    where v_row.to_email is not null
    on conflict (booking_id,template_code) where template_code='journey_tomorrow' do nothing;
    if found then v_queued:=v_queued+1; end if;
    update pace_v2.operational_alerts set resolved_at=now(),resolution_note='T-24 details corrected; reminder queued'
      where exception_key='t24_details_overdue:'||v_row.booking_id::text and resolved_at is null;
  end loop;
  return v_queued;
end;
$t24$;

revoke all on function public.v2_system_schedule_t24_journey_notifications(timestamp with time zone) from public,anon,authenticated;
grant execute on function public.v2_system_schedule_t24_journey_notifications(timestamp with time zone) to service_role;
