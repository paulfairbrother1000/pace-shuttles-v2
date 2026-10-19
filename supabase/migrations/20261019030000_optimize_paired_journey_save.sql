create or replace function pace_v2.admin_save_paired_journey_design(
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
  if v_existing_design.id is not null then
    -- The service already has return legs. Validate every eligible local
    -- operating date once, then update its paired rows in one statement. Calling
    -- materialize_service_return_leg once per generated date repeated route and
    -- timezone catalog lookups hundreds of times and timed out on long seasons.
    if exists(
      select 1
      from pace_v2.departures outbound
      where outbound.service_id=v_service.id
        and outbound.is_commercial
        and outbound.scheduled_departure_ts>now()
        and pace_v2.is_qualified_service_departure(v_service.id,outbound.id,p_outbound_local_time)
        and (
          (((outbound.local_departure_date::timestamp+p_return_local_time) at time zone v_return_route.trip_timezone) at time zone v_return_route.trip_timezone)::date is distinct from outbound.local_departure_date
          or (((outbound.local_departure_date::timestamp+p_return_local_time) at time zone v_return_route.trip_timezone) at time zone v_return_route.trip_timezone)::time is distinct from p_return_local_time
          or ((outbound.local_departure_date::timestamp+p_return_local_time) at time zone v_return_route.trip_timezone)<=outbound.scheduled_arrival_ts
        )
    ) then
      raise exception using errcode='22023',message='return local time does not exist or is not after outbound arrival for every operating date';
    end if;

    update pace_v2.departures return_leg
    set route_id=v_return_route.id,
        scheduled_departure_ts=(outbound.local_departure_date::timestamp+p_return_local_time) at time zone v_return_route.trip_timezone,
        scheduled_arrival_ts=((outbound.local_departure_date::timestamp+p_return_local_time) at time zone v_return_route.trip_timezone)+make_interval(mins=>p_return_duration_minutes),
        trip_timezone=v_return_route.trip_timezone,
        local_departure_date=outbound.local_departure_date,
        t72_ts=((outbound.local_departure_date::timestamp+p_return_local_time) at time zone v_return_route.trip_timezone)-make_interval(hours=>coalesce(v_return_route.t72_hours,72)),
        t24_ts=((outbound.local_departure_date::timestamp+p_return_local_time) at time zone v_return_route.trip_timezone)-make_interval(hours=>coalesce(v_return_route.t24_hours,24))
    from pace_v2.departures outbound
    join pace_v2.journey_pairs pair on pair.outbound_departure_id=outbound.id
    where return_leg.id=pair.return_departure_id
      and outbound.service_id=v_service.id
      and outbound.is_commercial
      and outbound.scheduled_departure_ts>now()
      and pace_v2.is_qualified_service_departure(v_service.id,outbound.id,p_outbound_local_time)
      and (
        return_leg.route_id is distinct from v_return_route.id
        or return_leg.scheduled_departure_ts is distinct from ((outbound.local_departure_date::timestamp+p_return_local_time) at time zone v_return_route.trip_timezone)
        or return_leg.scheduled_arrival_ts is distinct from (((outbound.local_departure_date::timestamp+p_return_local_time) at time zone v_return_route.trip_timezone)+make_interval(mins=>p_return_duration_minutes))
        or return_leg.trip_timezone is distinct from v_return_route.trip_timezone
        or return_leg.local_departure_date is distinct from outbound.local_departure_date
        or return_leg.t72_ts is distinct from (((outbound.local_departure_date::timestamp+p_return_local_time) at time zone v_return_route.trip_timezone)-make_interval(hours=>coalesce(v_return_route.t72_hours,72)))
        or return_leg.t24_ts is distinct from (((outbound.local_departure_date::timestamp+p_return_local_time) at time zone v_return_route.trip_timezone)-make_interval(hours=>coalesce(v_return_route.t24_hours,24)))
      );

    -- A newly generated commercial departure normally receives its return leg
    -- from the insert trigger. Materialize only any eligible unpaired rows.
    for v_outbound_id in
      select d.id
      from pace_v2.departures d
      where d.service_id=v_service.id
        and d.is_commercial
        and d.journey_pair_id is null
        and d.scheduled_departure_ts>now()
        and pace_v2.is_qualified_service_departure(v_service.id,d.id,p_outbound_local_time)
      order by d.scheduled_departure_ts,d.id
    loop
      v_return_id:=pace_v2.materialize_service_return_leg(v_outbound_id);
    end loop;
  else
    for v_outbound_id in
      select d.id
      from pace_v2.departures d
      where d.service_id=v_service.id
        and pace_v2.is_qualified_service_departure(v_service.id,d.id,p_outbound_local_time)
      order by d.scheduled_departure_ts,d.id
    loop
      v_return_id:=pace_v2.materialize_service_return_leg(v_outbound_id);
    end loop;
  end if;

  select pair.id,pair.outbound_departure_id,pair.return_departure_id
    into journey_pair_id,outbound_departure_id,return_departure_id
  from pace_v2.journey_pairs pair
  join pace_v2.departures outbound on outbound.id=pair.outbound_departure_id
  where outbound.service_id=v_service.id
    and outbound.scheduled_departure_ts>now()
    and pace_v2.is_qualified_service_departure(v_service.id,outbound.id,p_outbound_local_time)
  order by outbound.scheduled_departure_ts,outbound.id
  limit 1;
  updated_at:=v_design.updated_at;
  return next;
end $$;


revoke all on function pace_v2.admin_save_paired_journey_design(uuid,time,boolean,time,integer,uuid) from public,anon,authenticated;
grant execute on function pace_v2.admin_save_paired_journey_design(uuid,time,boolean,time,integer,uuid) to postgres;

