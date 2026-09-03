begin;

do $captain_duties_and_return_legs_contract$
declare
  v_admin_user_id uuid;
  v_service_id uuid;
  v_route_id uuid;
  v_timezone text;
  v_one_way_id uuid:=gen_random_uuid();
  v_outbound_id uuid:=gen_random_uuid();
  v_return_id uuid:=gen_random_uuid();
  v_pair_id uuid;
  v_other_pair_id uuid;
  v_rejected boolean;
begin
  select p.user_id into v_admin_user_id
  from pace_v2.profiles p
  where p.platform_role='site_admin'
  order by p.user_id
  limit 1;

  if v_admin_user_id is null then
    raise exception 'fixture: a site admin profile is required';
  end if;

  select d.service_id,d.route_id,d.trip_timezone
    into v_service_id,v_route_id,v_timezone
  from pace_v2.departures d
  where d.service_id is not null
  order by d.scheduled_departure_ts,d.id
  limit 1;

  if v_service_id is null then
    raise exception 'fixture: a scheduled service departure is required';
  end if;

  insert into pace_v2.departures(
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
    trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial
  ) values
    (v_one_way_id,v_service_id,v_route_id,'2098-01-10 10:00:00+00','2098-01-10 12:00:00+00',
     v_timezone,'2098-01-10','2098-01-07 10:00:00+00','2098-01-09 10:00:00+00','cancelled',true),
    (v_outbound_id,v_service_id,v_route_id,'2098-01-11 10:00:00+00','2098-01-11 12:00:00+00',
     v_timezone,'2098-01-11','2098-01-08 10:00:00+00','2098-01-10 10:00:00+00','cancelled',true),
    (v_return_id,v_service_id,v_route_id,'2098-01-11 16:00:00+00','2098-01-11 18:00:00+00',
     v_timezone,'2098-01-11','2098-01-08 16:00:00+00','2098-01-10 16:00:00+00','cancelled',false);

  v_rejected:=false;
  begin
    insert into pace_v2.departures(
      id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
      trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial
    ) values(
      gen_random_uuid(),v_service_id,v_route_id,'2098-01-11 20:00:00+00','2098-01-11 22:00:00+00',
      v_timezone,'2098-01-11','2098-01-08 20:00:00+00','2098-01-10 20:00:00+00','cancelled',true
    );
  exception when unique_violation then
    v_rejected:=true;
  end;
  if not v_rejected then
    raise exception 'second commercial departure on the same service day was accepted';
  end if;

  perform set_config('request.jwt.claim.sub',v_admin_user_id::text,true);
  v_rejected:=false;
  begin
    insert into pace_v2.journey_pairs(outbound_departure_id,return_departure_id)
    values(v_outbound_id,v_return_id);
  exception when others then
    v_rejected:=position('journey pairing may only change through protected lifecycle functions' in sqlerrm)>0;
  end;
  if not v_rejected then
    raise exception 'direct Site Admin journey pair creation was accepted';
  end if;

  perform set_config('pace_v2.journey_pair_mutation_authorized','on',true);
  insert into pace_v2.journey_pairs(outbound_departure_id,return_departure_id)
  values(v_outbound_id,v_return_id)
  returning id into v_pair_id;
  update pace_v2.departures
  set journey_pair_id=v_pair_id,
      leg_number=case id when v_outbound_id then 1 else 2 end
  where id in (v_outbound_id,v_return_id);
  perform set_config('pace_v2.journey_pair_mutation_authorized','off',true);
  set constraints all immediate;
  perform set_config('test.captain_pair_id',v_pair_id::text,true);
  perform set_config('test.captain_one_way_id',v_one_way_id::text,true);
  perform set_config('test.captain_return_id',v_return_id::text,true);

  set constraints all deferred;
  v_rejected:=false;
  begin
    perform set_config('pace_v2.journey_pair_mutation_authorized','on',true);
    update pace_v2.departures set leg_number=1 where id=v_return_id;
    set constraints all immediate;
  exception when unique_violation then
    v_rejected:=true;
  end;
  if not v_rejected then
    raise exception 'duplicate leg 1 was accepted';
  end if;

  set constraints all deferred;
  v_rejected:=false;
  begin
    perform set_config('pace_v2.journey_pair_mutation_authorized','on',true);
    insert into pace_v2.journey_pairs(outbound_departure_id,return_departure_id)
    values(v_one_way_id,v_outbound_id)
    returning id into v_other_pair_id;
    update pace_v2.departures
    set journey_pair_id=v_other_pair_id,
        leg_number=case id when v_one_way_id then 1 else 2 end
    where id in (v_one_way_id,v_outbound_id);
    set constraints all immediate;
  exception when unique_violation or check_violation then
    v_rejected:=true;
  end;
  if not v_rejected then
    raise exception 'the same departure was accepted in two journey pairs';
  end if;

  perform set_config('pace_v2.journey_pair_mutation_authorized','off',true);
  set constraints all deferred;
  v_rejected:=false;
  begin
    update pace_v2.journey_pairs
    set outbound_departure_id=v_return_id,return_departure_id=v_outbound_id
    where id=v_pair_id;
    update pace_v2.departures
    set leg_number=case id when v_return_id then 1 else 2 end
    where id in(v_outbound_id,v_return_id);
    set constraints all immediate;
  exception when others then
    v_rejected:=position('journey pairing may only change through protected lifecycle functions' in sqlerrm)>0;
  end;
  if not v_rejected then
    raise exception 'direct coordinated journey pair rewrite was accepted';
  end if;

  set constraints all deferred;
  v_rejected:=false;
  begin
    delete from pace_v2.journey_pairs where id=v_pair_id;
    update pace_v2.departures set journey_pair_id=null,leg_number=null
    where id in(v_outbound_id,v_return_id);
    set constraints all immediate;
  exception when others then
    v_rejected:=position('journey pairing may only change through protected lifecycle functions' in sqlerrm)>0;
  end;
  if not v_rejected then
    raise exception 'direct journey pair deletion was accepted';
  end if;

end
$captain_duties_and_return_legs_contract$;

select tests.assert_eq((select count(*) from pace_v2.departures where id=current_setting('test.captain_one_way_id')::uuid and journey_pair_id is null),1,'one-way departure retained');
select tests.assert_eq((select array_agg(leg_number order by leg_number) from pace_v2.departures where journey_pair_id=v_pair_id),array[1,2],'exactly two ordered legs')
from (select current_setting('test.captain_pair_id')::uuid as v_pair_id) fixture;

do $$ begin
  begin
    update pace_v2.departures set actual_arrival_ts=clock_timestamp()
    where id=current_setting('test.captain_one_way_id')::uuid;
  exception when others then
    raise exception 'ordinary one-way direct completion was rejected: %',sqlerrm;
  end;
  update pace_v2.departures set actual_arrival_ts=null
  where id=current_setting('test.captain_one_way_id')::uuid;
end $$;

do $paired_journey_design_save_contract$
declare
  v_admin_user_id uuid;
  v_source pace_v2.departures%rowtype;
  v_source_route pace_v2.routes%rowtype;
  v_route_id uuid:=gen_random_uuid();
  v_reverse_route_id uuid:=gen_random_uuid();
  v_unmapped_route_id uuid:=gen_random_uuid();
  v_no_departure_route_id uuid:=gen_random_uuid();
  v_no_departure_return_route_id uuid:=gen_random_uuid();
  v_service_id uuid:=gen_random_uuid();
  v_one_way_service_id uuid:=gen_random_uuid();
  v_no_departure_service_id uuid:=gen_random_uuid();
  v_outbound_id uuid:=gen_random_uuid();
  v_pre_generated_outbound_id uuid:=gen_random_uuid();
  v_generated_outbound_id uuid:=gen_random_uuid();
  v_post_edit_outbound_id uuid:=gen_random_uuid();
  v_one_way_outbound_id_1 uuid:=gen_random_uuid();
  v_one_way_outbound_id_2 uuid:=gen_random_uuid();
  v_protected_return_id uuid:=gen_random_uuid();
  v_protected_pair_id uuid;
  v_cancelled_outbound_id uuid:=gen_random_uuid();
  v_off_pattern_outbound_id uuid:=gen_random_uuid();
  v_stale_outbound_id uuid:=gen_random_uuid();
  v_stale_route_outbound_id uuid:=gen_random_uuid();
  v_null_recurrence_service_id uuid:=gen_random_uuid();
  v_large_recurrence_service_id uuid:=gen_random_uuid();
  v_operating_date date;
  v_no_departure_valid_from date;
  v_no_departure_expected_date date;
  v_recurrence_today date;
  v_large_recurrence_anchor date;
  v_large_recurrence_expected date;
  v_next_operating_date date;
  v_saved record;
  v_second_save record;
  v_outbound_edit record;
  v_no_departure_save record;
  v_pair_ids_before uuid[];
  v_pair_ids_after uuid[];
  v_return_ids_before uuid[];
  v_return_ids_after uuid[];
  v_return_schedules_before timestamptz[];
  v_return_schedules_after timestamptz[];
  v_all_pair_ids_before uuid[];
  v_all_pair_ids_after uuid[];
  v_all_return_ids_before uuid[];
  v_all_return_ids_after uuid[];
  v_state_before jsonb;
  v_state_after jsonb;
  v_removal_rejected boolean:=false;
  v_rejected boolean:=false;
  v_booking_id uuid;
  v_booking_departure_id uuid;
  v_booking_route_id uuid;
  v_consideration_id uuid;
  v_booking_allocation_id uuid;
  v_consideration_departure_id uuid;
  v_quote_id uuid;
  v_operation_source_allocation_id uuid;
  v_operation_allocation_id uuid;
  v_operation_assignment_id uuid;
  v_operation_captain_id uuid;
begin
  select user_id into v_admin_user_id from pace_v2.profiles where platform_role='site_admin' order by user_id limit 1;
  select d.* into v_source from pace_v2.departures d join pace_v2.routes r on r.id=d.route_id and r.is_active order by d.id limit 1;
  if v_source.id is null then raise exception 'fixture: an outbound departure is required'; end if;
  select * into v_source_route from pace_v2.routes where id=v_source.route_id;
  v_operating_date:=current_date+30+((1-extract(dow from current_date+30)::integer+7)%7);

  insert into pace_v2.routes(
    id,route_name,name,trip_timezone,pickup_id,destination_id,country_id,is_active,market_id,region_id,locality_id,
    approx_duration_mins,booking_lead_time_hours,t72_hours,t24_hours
  ) values (
    v_route_id,'Paired design outbound route','Paired design outbound route','Pacific/Kiritimati',
    v_source_route.pickup_id,v_source_route.destination_id,v_source_route.country_id,true,v_source_route.market_id,
    v_source_route.region_id,v_source_route.locality_id,coalesce(v_source_route.approx_duration_mins,120),
    v_source_route.booking_lead_time_hours,v_source_route.t72_hours,v_source_route.t24_hours
  ),(
    v_reverse_route_id,'Paired design reverse route','Paired design reverse route','Etc/GMT+12',
    -- Pickup points and destinations are separate ID domains. The Site Admin
    -- explicitly selects this operational return route; no UUID swapping.
    v_source_route.pickup_id,v_source_route.destination_id,v_source_route.country_id,true,v_source_route.market_id,
    v_source_route.region_id,v_source_route.locality_id,30,
    v_source_route.booking_lead_time_hours,v_source_route.t72_hours,v_source_route.t24_hours
  ),(
    v_unmapped_route_id,'Unmapped same-country route','Unmapped same-country route','Etc/GMT+12',
    v_source_route.pickup_id,v_source_route.destination_id,v_source_route.country_id,true,v_source_route.market_id,
    v_source_route.region_id,v_source_route.locality_id,30,
    v_source_route.booking_lead_time_hours,v_source_route.t72_hours,v_source_route.t24_hours
  );
  insert into pace_v2.services(id,route_id,name,active,timezone,days_of_week,departure_time,valid_from,valid_to)
  values
    (v_service_id,v_route_id,'Paired journey design service',true,'Pacific/Kiritimati',array[1]::smallint[],time '10:00',v_operating_date,null),
    (v_one_way_service_id,v_route_id,'One-way journey design service',true,'Pacific/Kiritimati',array[1]::smallint[],time '08:00',v_operating_date,null);
  insert into pace_v2.departures(
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,trip_timezone,local_departure_date,t72_ts,t24_ts,status
  ) values
  (
    v_outbound_id,v_service_id,v_route_id,
    (v_operating_date::timestamp+time '10:00') at time zone 'Pacific/Kiritimati',
    (v_operating_date::timestamp+time '12:00') at time zone 'Pacific/Kiritimati',
    'Pacific/Kiritimati',v_operating_date,
    ((v_operating_date::timestamp+time '10:00') at time zone 'Pacific/Kiritimati')-interval '72 hours',
    ((v_operating_date::timestamp+time '10:00') at time zone 'Pacific/Kiritimati')-interval '24 hours','scheduled'
  ),(
    v_pre_generated_outbound_id,v_service_id,v_route_id,
    ((v_operating_date+7)::timestamp+time '10:00') at time zone 'Pacific/Kiritimati',
    ((v_operating_date+7)::timestamp+time '12:00') at time zone 'Pacific/Kiritimati',
    'Pacific/Kiritimati',v_operating_date+7,
    (((v_operating_date+7)::timestamp+time '10:00') at time zone 'Pacific/Kiritimati')-interval '72 hours',
    (((v_operating_date+7)::timestamp+time '10:00') at time zone 'Pacific/Kiritimati')-interval '24 hours','scheduled'
  );

  insert into pace_v2.departures(
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,trip_timezone,local_departure_date,t72_ts,t24_ts,status
  ) values(
    v_one_way_outbound_id_1,v_one_way_service_id,v_route_id,
    ((v_operating_date+14)::timestamp+time '08:00') at time zone 'Pacific/Kiritimati',
    (((v_operating_date+14)::timestamp+time '08:00') at time zone 'Pacific/Kiritimati')+make_interval(mins=>coalesce(v_source_route.approx_duration_mins,120)),
    'Pacific/Kiritimati',v_operating_date+14,
    (((v_operating_date+14)::timestamp+time '08:00') at time zone 'Pacific/Kiritimati')-make_interval(hours=>coalesce(v_source_route.t72_hours,72)),
    (((v_operating_date+14)::timestamp+time '08:00') at time zone 'Pacific/Kiritimati')-make_interval(hours=>coalesce(v_source_route.t24_hours,24)),'scheduled'
  ),(
    v_one_way_outbound_id_2,v_one_way_service_id,v_route_id,
    ((v_operating_date+21)::timestamp+time '08:00') at time zone 'Pacific/Kiritimati',
    (((v_operating_date+21)::timestamp+time '08:00') at time zone 'Pacific/Kiritimati')+make_interval(mins=>coalesce(v_source_route.approx_duration_mins,120)),
    'Pacific/Kiritimati',v_operating_date+21,
    (((v_operating_date+21)::timestamp+time '08:00') at time zone 'Pacific/Kiritimati')-make_interval(hours=>coalesce(v_source_route.t72_hours,72)),
    (((v_operating_date+21)::timestamp+time '08:00') at time zone 'Pacific/Kiritimati')-make_interval(hours=>coalesce(v_source_route.t24_hours,24)),'scheduled'
  );

  perform set_config('request.jwt.claim.sub',v_admin_user_id::text,true);
  perform pace_v2.admin_save_paired_journey_design(
    p_service_id=>v_one_way_service_id,p_outbound_local_time=>'08:30',p_return_enabled=>false,
    p_return_local_time=>null,p_return_duration_minutes=>null,p_reverse_route_id=>null
  );
  if (select departure_time from pace_v2.services where id=v_one_way_service_id) is distinct from time '08:30'
     or (select count(*) from pace_v2.departures where id in(v_one_way_outbound_id_1,v_one_way_outbound_id_2))<>2
     or exists(
       select 1 from pace_v2.departures departure
       join pace_v2.routes route on route.id=departure.route_id
       where departure.id in(v_one_way_outbound_id_1,v_one_way_outbound_id_2)
         and (
           (departure.scheduled_departure_ts at time zone 'Pacific/Kiritimati')::time<>time '08:30'
           or departure.scheduled_arrival_ts<>departure.scheduled_departure_ts+make_interval(mins=>coalesce(route.approx_duration_mins,60))
           or departure.local_departure_date<>(departure.scheduled_departure_ts at time zone 'Pacific/Kiritimati')::date
           or departure.t72_ts<>departure.scheduled_departure_ts-make_interval(hours=>coalesce(route.t72_hours,72))
           or departure.t24_ts<>departure.scheduled_departure_ts-make_interval(hours=>coalesce(route.t24_hours,24))
           or departure.journey_pair_id is not null or departure.leg_number is not null
         )
     ) then raise exception 'disabled return outbound edit did not reschedule every pristine one-way departure'; end if;
  -- Repeating exactly the same disabled-return save must be a schedule no-op.
  select jsonb_agg(to_jsonb(departure) order by departure.id) into v_state_before
  from pace_v2.departures departure where departure.id in(v_one_way_outbound_id_1,v_one_way_outbound_id_2);
  perform pace_v2.admin_save_paired_journey_design(
    p_service_id=>v_one_way_service_id,p_outbound_local_time=>'08:30',p_return_enabled=>false,
    p_return_local_time=>null,p_return_duration_minutes=>null,p_reverse_route_id=>null
  );
  select jsonb_agg(to_jsonb(departure) order by departure.id) into v_state_after
  from pace_v2.departures departure where departure.id in(v_one_way_outbound_id_1,v_one_way_outbound_id_2);
  if v_state_after is distinct from v_state_before then raise exception 'same-time disabled return save changed a generated departure';end if;
  -- The mapping itself is the authoritative operational reverse relationship:
  -- a same-country route that was not mapped must still be rejected.
  perform public.v2_admin_save_route_return_mapping(v_route_id,v_reverse_route_id);

  select quote.id into v_quote_id from pace_v2.quote_intents quote order by quote.id limit 1;
  if v_quote_id is null then raise exception 'fixture: a quote intent is required for first return enable protection'; end if;
  begin
    update pace_v2.quote_intents set departure_id=v_one_way_outbound_id_2,expires_at=now()+interval '1 hour'
    where id=v_quote_id;
    v_rejected:=false;
    begin
      perform pace_v2.admin_save_paired_journey_design(
        p_service_id=>v_one_way_service_id,p_outbound_local_time=>'08:30',p_return_enabled=>true,
        p_return_local_time=>'16:00',p_return_duration_minutes=>30,p_reverse_route_id=>v_reverse_route_id
      );
    exception when others then
      v_rejected:=position('return journey cannot be enabled after bookings, allocations, active quotes, pairs or operation evidence exist' in sqlerrm)>0;
    end;
    if not v_rejected then raise exception 'active quote first return enable was not rejected atomically'; end if;
    if exists(select 1 from pace_v2.service_return_designs where service_id=v_one_way_service_id)
       or exists(select 1 from pace_v2.departures where id in(v_one_way_outbound_id_1,v_one_way_outbound_id_2) and journey_pair_id is not null) then
      raise exception 'active quote first return enable changed service design or departure pairing';
    end if;
    raise exception 'rollback active quote first-enable probe';
  exception when raise_exception then
    if sqlerrm<>'rollback active quote first-enable probe' then raise; end if;
  end;

  -- Enabling returns for the first time must preflight every future one-way
  -- promise. Even an externally paired row rejects the whole save before a
  -- design or any additional pair becomes visible.
  insert into pace_v2.departures(
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
    trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial
  ) values(
    v_protected_return_id,v_one_way_service_id,v_reverse_route_id,
    ((v_operating_date+15)::timestamp+time '16:00') at time zone 'Etc/GMT+12',
    ((v_operating_date+15)::timestamp+time '16:30') at time zone 'Etc/GMT+12',
    'Etc/GMT+12',v_operating_date+15,
    (((v_operating_date+15)::timestamp+time '16:00') at time zone 'Etc/GMT+12')-interval '72 hours',
    (((v_operating_date+15)::timestamp+time '16:00') at time zone 'Etc/GMT+12')-interval '24 hours',
    'scheduled',false
  );
  perform set_config('pace_v2.journey_pair_mutation_authorized','on',true);
  insert into pace_v2.journey_pairs(outbound_departure_id,return_departure_id)
  values(v_one_way_outbound_id_1,v_protected_return_id) returning id into v_protected_pair_id;
  update pace_v2.departures
  set journey_pair_id=v_protected_pair_id,
      leg_number=case when id=v_one_way_outbound_id_1 then 1 else 2 end
  where id in(v_one_way_outbound_id_1,v_protected_return_id);
  perform set_config('pace_v2.journey_pair_mutation_authorized','off',true);
  v_rejected:=false;
  begin
    perform pace_v2.admin_save_paired_journey_design(
      p_service_id=>v_one_way_service_id,p_outbound_local_time=>'08:30',p_return_enabled=>true,
      p_return_local_time=>'16:00',p_return_duration_minutes=>30,p_reverse_route_id=>v_reverse_route_id
    );
  exception when others then
    v_rejected:=position('return journey cannot be enabled after bookings, allocations, active quotes, pairs or operation evidence exist' in sqlerrm)>0;
  end;
  if not v_rejected then raise exception 'protected first return enable was not rejected atomically'; end if;
  if exists(select 1 from pace_v2.service_return_designs where service_id=v_one_way_service_id)
     or (select journey_pair_id from pace_v2.departures where id=v_one_way_outbound_id_1) is distinct from v_protected_pair_id
     or (select journey_pair_id from pace_v2.departures where id=v_one_way_outbound_id_2) is not null then
    raise exception 'protected first return enable changed service design or departure pairing';
  end if;
  perform set_config('pace_v2.journey_pair_mutation_authorized','on',true);
  update pace_v2.departures set journey_pair_id=null,leg_number=null
  where id in(v_one_way_outbound_id_1,v_protected_return_id);
  delete from pace_v2.journey_pairs where id=v_protected_pair_id;
  delete from pace_v2.departures where id=v_protected_return_id;
  perform set_config('pace_v2.journey_pair_mutation_authorized','off',true);
  perform pace_v2.admin_save_paired_journey_design(
    p_service_id=>v_one_way_service_id,p_outbound_local_time=>'08:30',p_return_enabled=>true,
    p_return_local_time=>'16:00',p_return_duration_minutes=>30,p_reverse_route_id=>v_reverse_route_id
  );
  if (select count(*) from pace_v2.departures
      where id in(v_one_way_outbound_id_1,v_one_way_outbound_id_2) and journey_pair_id is not null)<>2 then
    raise exception 'pristine first return enable did not pair every safe future departure';
  end if;

  v_rejected:=false;
  begin
    perform pace_v2.admin_save_paired_journey_design(
      p_service_id=>v_service_id,p_outbound_local_time=>'10:00',p_return_enabled=>true,
      p_return_local_time=>'16:00',p_return_duration_minutes=>30,p_reverse_route_id=>v_unmapped_route_id
    );
  exception when others then
    v_rejected:=position('mapped as the service route return' in sqlerrm)>0;
  end;
  if not v_rejected then raise exception 'an unmapped same-country route was accepted as a return'; end if;
  select * into v_saved from pace_v2.admin_save_paired_journey_design(
    p_service_id=>v_service_id,p_outbound_local_time=>'10:00',p_return_enabled=>true,
    p_return_local_time=>'16:00',p_return_duration_minutes=>30,p_reverse_route_id=>v_reverse_route_id
  );
  if v_saved.journey_pair_id is null or v_saved.outbound_departure_id is null or v_saved.return_departure_id is null then
    raise exception 'paired journey design save did not create both legs';
  end if;
  select array_agg(jp.id order by outbound.id),array_agg(jp.return_departure_id order by outbound.id)
    into v_pair_ids_before,v_return_ids_before
  from pace_v2.departures outbound
  join pace_v2.journey_pairs jp on jp.outbound_departure_id=outbound.id
  where outbound.id in(v_outbound_id,v_pre_generated_outbound_id);
  if cardinality(v_pair_ids_before)<>2 or cardinality(v_return_ids_before)<>2 then
    raise exception 'enable did not materialize every pre-generated recurrence date';
  end if;
  -- An idempotent Site Admin save is a true no-op even after a design is
  -- enabled; a changed mapping remains guarded by the mutation trigger below.
  perform public.v2_admin_save_route_return_mapping(v_route_id,v_reverse_route_id);
  if not exists(select 1 from pace_v2.route_return_mappings where outbound_route_id=v_route_id and return_route_id=v_reverse_route_id) then
    raise exception 'idempotent mapping RPC did not retain the enabled return mapping';
  end if;
  -- Both the protected RPC and direct table mutation must reject remapping an
  -- outbound route until every enabled service design has been disabled.
  v_rejected:=false;
  begin
    perform public.v2_admin_save_route_return_mapping(v_route_id,v_unmapped_route_id);
  exception when others then
    v_rejected:=position('return route mapping cannot change while a service return design is enabled' in sqlerrm)>0;
  end;
  if not v_rejected then raise exception 'mapping RPC remapped an enabled return design'; end if;
  v_rejected:=false;
  begin
    update pace_v2.route_return_mappings set return_route_id=v_unmapped_route_id where outbound_route_id=v_route_id;
  exception when others then
    v_rejected:=position('return route mapping cannot change while a service return design is enabled' in sqlerrm)>0;
  end;
  if not v_rejected then raise exception 'direct mapping update remapped an enabled return design'; end if;
  if not exists(
    select 1 from pace_v2.departures outbound
    join pace_v2.departures return_leg on return_leg.id=v_saved.return_departure_id
    join pace_v2.routes outbound_route on outbound_route.id=outbound.route_id
    join pace_v2.routes return_route on return_route.id=return_leg.route_id
    where outbound.id=v_saved.outbound_departure_id
      and outbound.journey_pair_id=v_saved.journey_pair_id and outbound.leg_number=1
      and return_leg.journey_pair_id=v_saved.journey_pair_id and return_leg.leg_number=2
      and return_leg.local_departure_date=outbound.local_departure_date
      and return_leg.scheduled_departure_ts=(outbound.local_departure_date::timestamp+time '16:00') at time zone return_route.trip_timezone
      and return_route.id=v_reverse_route_id
  ) then raise exception 'explicit return route, shared operating date or return time was not preserved'; end if;

  -- Insert a fresh outbound after the recurring design exists. The departure
  -- insert trigger must materialize its operational return automatically.
  insert into pace_v2.departures(
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,trip_timezone,local_departure_date,t72_ts,t24_ts,status
  ) values(
    v_generated_outbound_id,v_service_id,v_route_id,
    ((v_operating_date+35)::timestamp+time '10:00') at time zone 'Pacific/Kiritimati',
    ((v_operating_date+35)::timestamp+time '12:00') at time zone 'Pacific/Kiritimati',
    'Pacific/Kiritimati',v_operating_date+35,
    (((v_operating_date+35)::timestamp+time '10:00') at time zone 'Pacific/Kiritimati')-interval '72 hours',
    (((v_operating_date+35)::timestamp+time '10:00') at time zone 'Pacific/Kiritimati')-interval '24 hours','scheduled'
  );
  if not exists(
    select 1 from pace_v2.departures outbound
    join pace_v2.journey_pairs jp on jp.outbound_departure_id=outbound.id
    join pace_v2.departures return_leg on return_leg.id=jp.return_departure_id
    join pace_v2.routes return_route on return_route.id=return_leg.route_id
    where outbound.id=v_generated_outbound_id and outbound.leg_number=1
      and return_leg.leg_number=2 and not return_leg.is_commercial
      and return_route.id=v_reverse_route_id
      and return_leg.scheduled_departure_ts=(outbound.local_departure_date::timestamp+time '16:00') at time zone return_route.trip_timezone
  ) then raise exception 'new outbound departure did not materialize the saved return design'; end if;

  select array_agg(pair.id order by outbound.id),array_agg(pair.return_departure_id order by outbound.id)
    into v_all_pair_ids_before,v_all_return_ids_before
  from pace_v2.departures outbound
  join pace_v2.journey_pairs pair on pair.outbound_departure_id=outbound.id
  where outbound.id in(v_outbound_id,v_pre_generated_outbound_id,v_generated_outbound_id);
  select * into v_outbound_edit from pace_v2.admin_save_paired_journey_design(
    p_service_id=>v_service_id,p_outbound_local_time=>'10:30',p_return_enabled=>true,
    p_return_local_time=>'16:00',p_return_duration_minutes=>30,p_reverse_route_id=>v_reverse_route_id
  );
  select array_agg(pair.id order by outbound.id),array_agg(pair.return_departure_id order by outbound.id)
    into v_all_pair_ids_after,v_all_return_ids_after
  from pace_v2.departures outbound
  join pace_v2.journey_pairs pair on pair.outbound_departure_id=outbound.id
  where outbound.id in(v_outbound_id,v_pre_generated_outbound_id,v_generated_outbound_id);
  if v_all_pair_ids_after is distinct from v_all_pair_ids_before
     or v_all_return_ids_after is distinct from v_all_return_ids_before
     or v_outbound_edit.outbound_departure_id is distinct from v_saved.outbound_departure_id then
    raise exception 'enabled outbound edit did not retain departure, pair and return identities';
  end if;
  if (select departure_time from pace_v2.services where id=v_service_id) is distinct from time '10:30'
     or exists(
       select 1
       from pace_v2.departures outbound
       join pace_v2.journey_pairs pair on pair.outbound_departure_id=outbound.id
       join pace_v2.departures return_leg on return_leg.id=pair.return_departure_id
       join pace_v2.routes outbound_route on outbound_route.id=outbound.route_id
       join pace_v2.routes return_route on return_route.id=return_leg.route_id
       where outbound.id in(v_outbound_id,v_pre_generated_outbound_id,v_generated_outbound_id)
         and (
           (outbound.scheduled_departure_ts at time zone 'Pacific/Kiritimati')::time<>time '10:30'
           or outbound.scheduled_arrival_ts<>outbound.scheduled_departure_ts+make_interval(mins=>coalesce(outbound_route.approx_duration_mins,60))
           or outbound.local_departure_date<>(outbound.scheduled_departure_ts at time zone 'Pacific/Kiritimati')::date
           or outbound.t72_ts<>outbound.scheduled_departure_ts-make_interval(hours=>coalesce(outbound_route.t72_hours,72))
           or outbound.t24_ts<>outbound.scheduled_departure_ts-make_interval(hours=>coalesce(outbound_route.t24_hours,24))
           or (return_leg.scheduled_departure_ts at time zone return_route.trip_timezone)::time<>time '16:00'
           or return_leg.local_departure_date<>outbound.local_departure_date
         )
     ) then raise exception 'enabled outbound edit did not synchronize every outbound and return timestamp'; end if;

  -- Historical/cancelled/manual rows remain compatible, while future scheduled
  -- commercial service rows must match the schedule protected by the service
  -- and design locks before they become visible.
  insert into pace_v2.departures(
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,trip_timezone,local_departure_date,t72_ts,t24_ts,status
  ) values(
    v_cancelled_outbound_id,v_service_id,v_route_id,
    ((v_operating_date+14)::timestamp+time '10:00') at time zone 'Pacific/Kiritimati',
    ((v_operating_date+14)::timestamp+time '12:00') at time zone 'Pacific/Kiritimati','Pacific/Kiritimati',v_operating_date+14,
    (((v_operating_date+14)::timestamp+time '10:00') at time zone 'Pacific/Kiritimati')-interval '72 hours',
    (((v_operating_date+14)::timestamp+time '10:00') at time zone 'Pacific/Kiritimati')-interval '24 hours','cancelled'
  );
  v_rejected:=false;
  begin
    insert into pace_v2.departures(id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,trip_timezone,local_departure_date,t72_ts,t24_ts,status)
    values(v_stale_outbound_id,v_service_id,v_route_id,
      ((v_operating_date+21)::timestamp+time '10:00') at time zone 'Pacific/Kiritimati',
      ((v_operating_date+21)::timestamp+time '12:00') at time zone 'Pacific/Kiritimati','Pacific/Kiritimati',v_operating_date+21,
      (((v_operating_date+21)::timestamp+time '10:00') at time zone 'Pacific/Kiritimati')-interval '72 hours',
      (((v_operating_date+21)::timestamp+time '10:00') at time zone 'Pacific/Kiritimati')-interval '24 hours','scheduled');
  exception when sqlstate '40001' then
    v_rejected:=sqlerrm='stale generated departure schedule; retry generation';
  end;
  if not v_rejected then raise exception 'stale pre-edit generator insert was not rejected with retryable domain error';end if;

  v_rejected:=false;
  begin
    insert into pace_v2.departures(id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,trip_timezone,local_departure_date,t72_ts,t24_ts,status)
    values(v_off_pattern_outbound_id,v_service_id,v_route_id,
      ((v_operating_date+15)::timestamp+time '10:30') at time zone 'Pacific/Kiritimati',
      ((v_operating_date+15)::timestamp+time '12:30') at time zone 'Pacific/Kiritimati','Pacific/Kiritimati',v_operating_date+15,
      (((v_operating_date+15)::timestamp+time '10:30') at time zone 'Pacific/Kiritimati')-interval '72 hours',
      (((v_operating_date+15)::timestamp+time '10:30') at time zone 'Pacific/Kiritimati')-interval '24 hours','scheduled');
  exception when sqlstate '40001' then v_rejected:=true; end;
  if not v_rejected then raise exception 'off-pattern generated departure was accepted';end if;

  v_rejected:=false;
  begin
    insert into pace_v2.departures(id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,trip_timezone,local_departure_date,t72_ts,t24_ts,status)
    values(v_stale_route_outbound_id,v_service_id,v_unmapped_route_id,
      ((v_operating_date+28)::timestamp+time '10:30') at time zone 'Etc/GMT+12',
      ((v_operating_date+28)::timestamp+time '11:00') at time zone 'Etc/GMT+12','Etc/GMT+12',v_operating_date+28,
      (((v_operating_date+28)::timestamp+time '10:30') at time zone 'Etc/GMT+12')-interval '72 hours',
      (((v_operating_date+28)::timestamp+time '10:30') at time zone 'Etc/GMT+12')-interval '24 hours','scheduled');
  exception when sqlstate '40001' then v_rejected:=true; end;
  if not v_rejected then raise exception 'stale-route generated departure was accepted';end if;

  insert into pace_v2.departures(id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,trip_timezone,local_departure_date,t72_ts,t24_ts,status)
  values(v_post_edit_outbound_id,v_service_id,v_route_id,
    ((v_operating_date+28)::timestamp+time '10:30') at time zone 'Pacific/Kiritimati',
    ((v_operating_date+28)::timestamp+time '12:30') at time zone 'Pacific/Kiritimati','Pacific/Kiritimati',v_operating_date+28,
    (((v_operating_date+28)::timestamp+time '10:30') at time zone 'Pacific/Kiritimati')-interval '72 hours',
    (((v_operating_date+28)::timestamp+time '10:30') at time zone 'Pacific/Kiritimati')-interval '24 hours','scheduled');
  if not exists(
    select 1 from pace_v2.departures outbound
    join pace_v2.journey_pairs pair on pair.outbound_departure_id=outbound.id
    join pace_v2.departures return_leg on return_leg.id=pair.return_departure_id
    where outbound.id=v_post_edit_outbound_id
      and (outbound.scheduled_departure_ts at time zone 'Pacific/Kiritimati')::time=time '10:30'
      and return_leg.leg_number=2 and not return_leg.is_commercial
  ) then raise exception 'valid post-edit generator insert did not retain the current service schedule and materialize its return';end if;

  -- This service deliberately has no generated departure. Its only valid date
  -- is the weekday/anchor date below, forcing save through next-valid-date
  -- validation in the service operating timezone.
  v_no_departure_valid_from:=(now() at time zone 'Pacific/Kiritimati')::date+7;
  v_no_departure_expected_date:=v_no_departure_valid_from+1;
  insert into pace_v2.routes(
    id,route_name,name,trip_timezone,pickup_id,destination_id,country_id,is_active,market_id,region_id,locality_id,
    approx_duration_mins,booking_lead_time_hours,t72_hours,t24_hours
  ) values(
    v_no_departure_route_id,'No-departure outbound route','No-departure outbound route','Pacific/Kiritimati',
    v_source_route.pickup_id,v_source_route.destination_id,v_source_route.country_id,true,v_source_route.market_id,
    v_source_route.region_id,v_source_route.locality_id,120,v_source_route.booking_lead_time_hours,v_source_route.t72_hours,v_source_route.t24_hours
  ),(
    v_no_departure_return_route_id,'No-departure return route','No-departure return route','Etc/GMT+12',
    v_source_route.pickup_id,v_source_route.destination_id,v_source_route.country_id,true,v_source_route.market_id,
    v_source_route.region_id,v_source_route.locality_id,30,v_source_route.booking_lead_time_hours,v_source_route.t72_hours,v_source_route.t24_hours
  );
  perform public.v2_admin_save_route_return_mapping(v_no_departure_route_id,v_no_departure_return_route_id);
  insert into pace_v2.services(id,route_id,name,active,timezone,days_of_week,departure_time,valid_from,valid_to,recurrence_type,recurrence_interval_weeks,recurrence_anchor_date)
  values(v_no_departure_service_id,v_no_departure_route_id,'No-departure recurrence service',true,'Pacific/Kiritimati',array[extract(dow from v_no_departure_expected_date)::smallint],time '09:00',v_no_departure_valid_from,v_no_departure_expected_date,'weekly',2,v_no_departure_expected_date);
  select * into v_no_departure_save from pace_v2.admin_save_paired_journey_design(
    p_service_id=>v_no_departure_service_id,p_outbound_local_time=>'09:00',p_return_enabled=>true,
    p_return_local_time=>'16:00',p_return_duration_minutes=>30,p_reverse_route_id=>v_no_departure_return_route_id
  );
  if v_no_departure_save.outbound_departure_id is not null or not exists(
    select 1 from pace_v2.service_return_designs d
    where d.service_id=v_no_departure_service_id and d.reverse_route_id=v_no_departure_return_route_id
  ) then raise exception 'next valid operating date did not retain the no-departure recurrence design'; end if;

  -- The arithmetic helper must remain bounded even with no anchor/valid-from
  -- and with a large weekly interval.  It must also calculate a distant
  -- finite-valid-to occurrence exactly rather than scanning calendar dates.
  v_recurrence_today:=(now() at time zone 'Pacific/Kiritimati')::date;
  insert into pace_v2.services(id,route_id,name,active,timezone,days_of_week,departure_time,valid_from,valid_to,recurrence_type,recurrence_interval_weeks,recurrence_anchor_date)
  values(
    v_null_recurrence_service_id,v_no_departure_route_id,'Null-anchor recurrence service',true,'Pacific/Kiritimati',
    array[extract(dow from v_recurrence_today)::smallint],time '00:00',null,null,'weekly',52000,null
  );
  v_next_operating_date:=pace_v2.next_service_operating_date(v_null_recurrence_service_id,time '00:00');
  if v_next_operating_date is null or v_next_operating_date<v_recurrence_today or v_next_operating_date>v_recurrence_today+7 then
    raise exception 'null-anchor/null-valid-from recurrence did not find its bounded next date';
  end if;
  v_large_recurrence_anchor:=v_recurrence_today-280000;
  v_large_recurrence_expected:=v_large_recurrence_anchor+350000;
  insert into pace_v2.services(id,route_id,name,active,timezone,days_of_week,departure_time,valid_from,valid_to,recurrence_type,recurrence_interval_weeks,recurrence_anchor_date)
  values(
    v_large_recurrence_service_id,v_no_departure_route_id,'Large-interval recurrence service',true,'Pacific/Kiritimati',
    array[extract(dow from v_large_recurrence_anchor)::smallint],time '00:00',null,v_large_recurrence_expected+7,'weekly',50000,v_large_recurrence_anchor
  );
  v_next_operating_date:=pace_v2.next_service_operating_date(v_large_recurrence_service_id,time '00:00');
  if v_next_operating_date is distinct from v_large_recurrence_expected then
    raise exception 'large-interval recurrence did not calculate the distant valid operating date';
  end if;
  v_rejected:=false;
  begin
    delete from pace_v2.route_return_mappings where outbound_route_id=v_no_departure_route_id;
  exception when others then
    v_rejected:=position('return route mapping cannot change while a service return design is enabled' in sqlerrm)>0;
  end;
  if not v_rejected then raise exception 'mapping deletion removed an enabled return design'; end if;
  update pace_v2.services set active=false where id=v_no_departure_service_id;
  update pace_v2.routes set is_active=false where id=v_no_departure_route_id;
  perform pace_v2.admin_save_paired_journey_design(
    p_service_id=>v_no_departure_service_id,p_outbound_local_time=>'09:00',p_return_enabled=>false,
    p_return_local_time=>null,p_return_duration_minutes=>null,p_reverse_route_id=>null
  );
  if exists(select 1 from pace_v2.service_return_designs where service_id=v_no_departure_service_id) then raise exception 'inactive service or route blocked safe return design disable'; end if;
  delete from pace_v2.route_return_mappings where outbound_route_id=v_no_departure_route_id;

  select * into v_second_save from pace_v2.admin_save_paired_journey_design(
    p_service_id=>v_service_id,p_outbound_local_time=>'10:30',p_return_enabled=>true,
    p_return_local_time=>'16:15',p_return_duration_minutes=>35,p_reverse_route_id=>v_reverse_route_id
  );
  if v_second_save.journey_pair_id is distinct from v_saved.journey_pair_id then
    raise exception 'repeated design save did not retain the same journey pair';
  end if;
  select array_agg(jp.id order by outbound.id),array_agg(jp.return_departure_id order by outbound.id)
    into v_pair_ids_after,v_return_ids_after
  from pace_v2.departures outbound
  join pace_v2.journey_pairs jp on jp.outbound_departure_id=outbound.id
  where outbound.id in(v_outbound_id,v_pre_generated_outbound_id);
  if v_pair_ids_after is distinct from v_pair_ids_before
     or v_return_ids_after is distinct from v_return_ids_before then
    raise exception 'repeated design save changed a journey pair or return departure identity';
  end if;
  if exists(
    select 1
    from pace_v2.departures outbound
    join pace_v2.journey_pairs jp on jp.outbound_departure_id=outbound.id
    join pace_v2.departures return_leg on return_leg.id=jp.return_departure_id
    join pace_v2.routes return_route on return_route.id=return_leg.route_id
    where outbound.id in(v_outbound_id,v_pre_generated_outbound_id)
      and (
        (return_leg.scheduled_departure_ts at time zone return_route.trip_timezone)::time<>time '16:15'
        or return_leg.scheduled_arrival_ts<>return_leg.scheduled_departure_ts+interval '35 minutes'
      )
  ) then
    raise exception 'schedule edit did not update every pristine future return leg';
  end if;
  select b.id,b.departure_id,b.route_id into v_booking_id,v_booking_departure_id,v_booking_route_id from pace_v2.bookings b order by b.id limit 1;
  if v_booking_id is null then raise exception 'fixture: a booking is required to test protected return removal'; end if;
  update pace_v2.bookings set departure_id=v_second_save.outbound_departure_id,route_id=v_route_id where id=v_booking_id;
  select jsonb_build_object(
    'service_time',(select departure_time::text from pace_v2.services where id=v_service_id),
    'design',(select to_jsonb(design) from pace_v2.service_return_designs design where design.service_id=v_service_id),
    'departures',(select jsonb_agg(to_jsonb(departure) order by departure.id) from pace_v2.departures departure where departure.id=any(v_all_return_ids_before) or departure.id in(v_outbound_id,v_pre_generated_outbound_id,v_generated_outbound_id)),
    'pairs',(select jsonb_agg(to_jsonb(pair) order by pair.id) from pace_v2.journey_pairs pair where pair.id=any(v_all_pair_ids_before))
  ) into v_state_before;
  v_rejected:=false;
  begin
    perform pace_v2.admin_save_paired_journey_design(
      p_service_id=>v_service_id,p_outbound_local_time=>'11:00',p_return_enabled=>true,
      p_return_local_time=>'16:15',p_return_duration_minutes=>35,p_reverse_route_id=>v_reverse_route_id
    );
  exception when others then
    v_rejected:=position('outbound journey time cannot change after bookings, allocations or operation evidence exist' in sqlerrm)>0;
  end;
  if not v_rejected then raise exception 'protected outbound edit was not rejected atomically'; end if;
  select jsonb_build_object(
    'service_time',(select departure_time::text from pace_v2.services where id=v_service_id),
    'design',(select to_jsonb(design) from pace_v2.service_return_designs design where design.service_id=v_service_id),
    'departures',(select jsonb_agg(to_jsonb(departure) order by departure.id) from pace_v2.departures departure where departure.id=any(v_all_return_ids_before) or departure.id in(v_outbound_id,v_pre_generated_outbound_id,v_generated_outbound_id)),
    'pairs',(select jsonb_agg(to_jsonb(pair) order by pair.id) from pace_v2.journey_pairs pair where pair.id=any(v_all_pair_ids_before))
  ) into v_state_after;
  if v_state_after is distinct from v_state_before then raise exception 'protected outbound edit partially changed service, departure, pair or return state';end if;
  select array_agg(return_leg.scheduled_departure_ts order by outbound.id)
    into v_return_schedules_before
  from pace_v2.departures outbound
  join pace_v2.journey_pairs jp on jp.outbound_departure_id=outbound.id
  join pace_v2.departures return_leg on return_leg.id=jp.return_departure_id
  where outbound.id in(v_outbound_id,v_pre_generated_outbound_id);
  v_rejected:=false;
  begin
    perform pace_v2.admin_save_paired_journey_design(
      p_service_id=>v_service_id,p_outbound_local_time=>'10:30',p_return_enabled=>true,
      p_return_local_time=>'16:30',p_return_duration_minutes=>40,p_reverse_route_id=>v_reverse_route_id
    );
  exception when others then
    v_rejected:=position('return journey design cannot change after bookings, allocations or operation evidence exist' in sqlerrm)>0;
  end;
  if not v_rejected then raise exception 'protected design edit was not rejected atomically'; end if;
  select array_agg(return_leg.scheduled_departure_ts order by outbound.id)
    into v_return_schedules_after
  from pace_v2.departures outbound
  join pace_v2.journey_pairs jp on jp.outbound_departure_id=outbound.id
  join pace_v2.departures return_leg on return_leg.id=jp.return_departure_id
  where outbound.id in(v_outbound_id,v_pre_generated_outbound_id);
  if v_return_schedules_after is distinct from v_return_schedules_before
     or not exists(
       select 1 from pace_v2.service_return_designs design
       where design.service_id=v_service_id
         and design.return_local_time=time '16:15'
         and design.return_duration_minutes=35
     ) then
    raise exception 'protected design edit partially changed return schedules or design';
  end if;
  begin
    perform pace_v2.admin_save_paired_journey_design(
      p_service_id=>v_service_id,p_outbound_local_time=>'10:30',p_return_enabled=>false,
      p_return_local_time=>null,p_return_duration_minutes=>null,p_reverse_route_id=>null
    );
  exception when others then
    v_removal_rejected:=position('return journey cannot be removed after bookings, allocations or operation evidence exist' in sqlerrm)>0;
  end;
  if not v_removal_rejected then raise exception 'protected removal accepted a booking'; end if;
  update pace_v2.bookings set departure_id=v_booking_departure_id,route_id=v_booking_route_id where id=v_booking_id;
  v_removal_rejected:=false;
  select ba.id,vc.id,vc.departure_id into v_booking_allocation_id,v_consideration_id,v_consideration_departure_id from pace_v2.booking_allocations ba join pace_v2.vehicle_considerations vc on vc.id=ba.vehicle_consideration_id order by ba.id limit 1;
  if v_booking_allocation_id is null then raise exception 'fixture: a booking allocation is required to test protected return removal'; end if;
  update pace_v2.vehicle_considerations set departure_id=v_second_save.outbound_departure_id where id=v_consideration_id;
  begin
    perform pace_v2.admin_save_paired_journey_design(
      p_service_id=>v_service_id,p_outbound_local_time=>'10:30',p_return_enabled=>false,
      p_return_local_time=>null,p_return_duration_minutes=>null,p_reverse_route_id=>null
    );
  exception when others then
    v_removal_rejected:=position('return journey cannot be removed after bookings, allocations or operation evidence exist' in sqlerrm)>0;
  end;
  if not v_removal_rejected then raise exception 'protected removal accepted an allocation'; end if;
  update pace_v2.vehicle_considerations set departure_id=v_consideration_departure_id where id=v_consideration_id;
  v_removal_rejected:=false;
  v_rejected:=false;
  begin
    update pace_v2.departures set actual_departure_ts=now()
    where id=v_second_save.return_departure_id;
  exception when others then
    v_rejected:=position('paired duty must be started with v2_captain_start_leg' in sqlerrm)>0;
  end;
  if not v_rejected then raise exception 'direct paired legacy start was accepted'; end if;

  select allocation.id,captain.id
    into v_operation_source_allocation_id,v_operation_captain_id
  from pace_v2.confirmed_allocations allocation
  join pace_v2.vehicles vehicle on vehicle.id=allocation.vehicle_id and vehicle.active
  join pace_v2.captain_assignments assignment
    on assignment.confirmed_allocation_id=allocation.id and assignment.active
  join pace_v2.captains captain
    on captain.id=assignment.captain_id and captain.active
   and captain.operator_id=allocation.operator_id
  join pace_v2.captain_vehicle_types eligibility
    on eligibility.captain_id=captain.id
   and eligibility.vehicle_type_id=vehicle.vehicle_type_id and eligibility.active
  where allocation.status='confirmed'
  order by allocation.id,assignment.id
  limit 1;
  if v_operation_source_allocation_id is null then
    raise exception 'fixture: a confirmed allocation with an active captain assignment is required';
  end if;

  -- A return-leg operation must belong to an allocation on the paired
  -- outbound. Clone only the minimal allocation identity for this rollback
  -- probe instead of borrowing an unrelated live allocation.
  insert into pace_v2.confirmed_allocations(
    departure_id,vehicle_id,operator_id,consideration_id,confirmed_at,confirmed_by,
    operator_journey_value_cents,effective_commission_bps,
    pace_shuttles_commission_cents,operator_net_before_adjustments_cents,
    status,completed_at,created_at
  )
  select v_second_save.outbound_departure_id,source.vehicle_id,source.operator_id,null,
    clock_timestamp(),'captain_fixture',source.operator_journey_value_cents,
    source.effective_commission_bps,source.pace_shuttles_commission_cents,
    source.operator_net_before_adjustments_cents,'confirmed',null,clock_timestamp()
  from pace_v2.confirmed_allocations source
  where source.id=v_operation_source_allocation_id
  returning id into v_operation_allocation_id;

  insert into pace_v2.captain_assignments(confirmed_allocation_id,captain_id,active)
  values(v_operation_allocation_id,v_operation_captain_id,true)
  returning id into v_operation_assignment_id;

  insert into pace_v2.captain_leg_operations(
    confirmed_allocation_id,departure_id,captain_assignment_id,started_at
  ) values(
    v_operation_allocation_id,v_second_save.return_departure_id,v_operation_assignment_id,now()
  );
  begin
    perform pace_v2.admin_save_paired_journey_design(
      p_service_id=>v_service_id,p_outbound_local_time=>'10:30',p_return_enabled=>false,
      p_return_local_time=>null,p_return_duration_minutes=>null,p_reverse_route_id=>null
    );
  exception when others then
    v_removal_rejected:=position('return journey cannot be removed after bookings, allocations or operation evidence exist' in sqlerrm)>0;
  end;
  if not v_removal_rejected then raise exception 'protected removal accepted operation evidence'; end if;
  delete from pace_v2.captain_leg_operations
  where confirmed_allocation_id=v_operation_allocation_id;
  delete from pace_v2.captain_assignments
  where id=v_operation_assignment_id;
  delete from pace_v2.confirmed_allocations
  where id=v_operation_allocation_id;
end
$paired_journey_design_save_contract$;

do $paired_journey_internal_helper_acl_contract$
begin
  if has_function_privilege('public','pace_v2.is_qualified_service_departure(uuid,uuid,time without time zone)','execute')
     or has_function_privilege('anon','pace_v2.is_qualified_service_departure(uuid,uuid,time without time zone)','execute')
     or has_function_privilege('authenticated','pace_v2.is_qualified_service_departure(uuid,uuid,time without time zone)','execute')
     or has_function_privilege('public','pace_v2.next_service_operating_date(uuid,time without time zone)','execute')
     or has_function_privilege('anon','pace_v2.next_service_operating_date(uuid,time without time zone)','execute')
     or has_function_privilege('authenticated','pace_v2.next_service_operating_date(uuid,time without time zone)','execute')
     or has_function_privilege('public','pace_v2.materialize_service_return_leg(uuid)','execute')
     or has_function_privilege('anon','pace_v2.materialize_service_return_leg(uuid)','execute')
     or has_function_privilege('authenticated','pace_v2.materialize_service_return_leg(uuid)','execute') then
    raise exception 'paired journey internal SECURITY DEFINER helpers are executable by an API role';
  end if;
end
$paired_journey_internal_helper_acl_contract$;

-- Captain Today is a rollback-only operational lifecycle over one clean seeded
-- allocation. The commercial allocation remains attached only to the outbound;
-- the return receives no booking, consideration, or confirmed allocation.
create temporary table captain_today_fixture(
  allocation_id uuid not null,
  assignment_id uuid not null,
  captain_id uuid not null,
  outbound_id uuid not null,
  return_id uuid not null default gen_random_uuid(),
  pair_id uuid,
  booking_id uuid not null,
  captain_user_id uuid not null,
  customer_user_id uuid not null,
  other_captain_user_id uuid not null,
  operator_user_id uuid not null,
  allocation_2_id uuid,
  source_allocation_2_id uuid,
  allocation_2_original_departure_id uuid,
  consideration_2_id uuid,
  assignment_2_id uuid,
  original_assignment_2_id uuid,
  captain_2_id uuid,
  captain_2_user_id uuid,
  booking_2_id uuid,
  private_request_id uuid,
  private_conversation_id uuid,
  start_1 timestamptz,
  end_1 timestamptz,
  start_2 timestamptz,
  end_2 timestamptz,
  end_2_allocation_2 timestamptz,
  legacy_departure_arrival_before_retry timestamptz,
  legacy_voyage_arrival_before_retry timestamptz,
  voyage_log_count integer not null default 0,
  completed_voyage_count integer not null default 0,
  feedback_count integer not null default 0,
  completed_voyage_2_count integer not null default 0,
  feedback_2_count integer not null default 0
) on commit drop;
grant select,update on captain_today_fixture to authenticated;
grant select on captain_today_fixture to anon;

insert into captain_today_fixture(
  allocation_id,assignment_id,captain_id,outbound_id,booking_id,captain_user_id,
  customer_user_id,other_captain_user_id,operator_user_id,captain_2_user_id
)
select ca.id,gen_random_uuid(),gen_random_uuid(),d.id,gen_random_uuid(),gen_random_uuid(),
  gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid()
from pace_v2.confirmed_allocations ca
join pace_v2.departures d on d.id=ca.departure_id
  and d.journey_pair_id is null
  and d.actual_departure_ts is null and d.actual_arrival_ts is null
join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
where ca.status='confirmed' and ca.consideration_id is not null
order by ca.id limit 1;

-- Production may have only one active captain and two confirmed allocations.
-- Seed two independent captain identities and clone (rather than consume) the
-- second allocation so the one-way compatibility fixture remains available.
do $captain_today_seed_independent_identities$
declare
  fixture captain_today_fixture%rowtype;
  source_allocation pace_v2.confirmed_allocations%rowtype;
  primary_consideration pace_v2.vehicle_considerations%rowtype;
  primary_offer pace_v2.vehicle_route_offers%rowtype;
  v_primary_operator_id uuid;
  v_primary_vehicle_id uuid;
  v_primary_vehicle_type_id uuid;
  v_primary_consideration_id uuid;
  v_primary_route_id uuid;
  v_primary_service_id uuid;
  v_second_vehicle_id uuid;
  v_second_vehicle_type_id uuid;
  v_second_booking_id uuid;
  v_second_consideration_id uuid;
  v_second_offer_id uuid:=gen_random_uuid();
  v_second_captain_id uuid;
  v_other_captain_id uuid;
  v_second_allocation_id uuid;
  v_second_assignment_id uuid;
  v_primary_order_id uuid;
  v_second_order_id uuid;
  v_auth_instance_id uuid;
begin
  select * into fixture from captain_today_fixture limit 1;
  if not found then return; end if;

  select identity.instance_id into v_auth_instance_id
  from auth.users identity order by identity.created_at nulls last,identity.id limit 1;
  if v_auth_instance_id is null then
    raise exception 'fixture: source auth instance required';
  end if;

  insert into auth.users(
    id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
    raw_app_meta_data,raw_user_meta_data,created_at,updated_at,is_sso_user,is_anonymous
  ) values
    (fixture.captain_user_id,v_auth_instance_id,'authenticated','authenticated',
     'captain-fixture+'||replace(fixture.captain_user_id::text,'-','')||'@example.invalid','',now(),
     '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now(),false,false),
    (fixture.customer_user_id,v_auth_instance_id,'authenticated','authenticated',
     'customer-fixture+'||replace(fixture.customer_user_id::text,'-','')||'@example.invalid','',now(),
     '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now(),false,false),
    (fixture.captain_2_user_id,v_auth_instance_id,'authenticated','authenticated',
     'captain-fixture+'||replace(fixture.captain_2_user_id::text,'-','')||'@example.invalid','',now(),
     '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now(),false,false),
    (fixture.other_captain_user_id,v_auth_instance_id,'authenticated','authenticated',
     'captain-fixture+'||replace(fixture.other_captain_user_id::text,'-','')||'@example.invalid','',now(),
     '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now(),false,false),
    (fixture.operator_user_id,v_auth_instance_id,'authenticated','authenticated',
     'operator-fixture+'||replace(fixture.operator_user_id::text,'-','')||'@example.invalid','',now(),
     '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now(),false,false);
  insert into pace_v2.profiles(user_id,platform_role) values
    (fixture.captain_user_id,'customer'),
    (fixture.customer_user_id,'customer'),
    (fixture.captain_2_user_id,'customer'),
    (fixture.other_captain_user_id,'customer'),
    (fixture.operator_user_id,'customer')
  on conflict(user_id) do update set platform_role=excluded.platform_role;

  select allocation.operator_id,allocation.vehicle_id,vehicle.vehicle_type_id,
      allocation.consideration_id,departure.route_id,departure.service_id
    into v_primary_operator_id,v_primary_vehicle_id,v_primary_vehicle_type_id,
      v_primary_consideration_id,v_primary_route_id,v_primary_service_id
  from pace_v2.confirmed_allocations allocation
  join pace_v2.departures departure on departure.id=allocation.departure_id
  join pace_v2.vehicles vehicle on vehicle.id=allocation.vehicle_id
  where allocation.id=fixture.allocation_id;

  insert into pace_v2.operator_memberships(user_id,operator_id,role,active)
  values(fixture.operator_user_id,v_primary_operator_id,'operator_user',true);

  insert into pace_v2.captains(
    id,operator_id,first_name,last_name,email,auth_user_id,active
  ) values(
    fixture.captain_id,v_primary_operator_id,'Rollback','Captain One',
    'captain-fixture+'||replace(fixture.captain_user_id::text,'-','')||'@example.invalid',
    fixture.captain_user_id,true
  );
  insert into pace_v2.captain_vehicle_types(captain_id,vehicle_type_id,active)
  values(fixture.captain_id,v_primary_vehicle_type_id,true);
  update pace_v2.captain_assignments set active=false
  where confirmed_allocation_id=fixture.allocation_id and active;
  insert into pace_v2.captain_assignments(
    id,confirmed_allocation_id,captain_id,assignment_source,active
  ) values(fixture.assignment_id,fixture.allocation_id,fixture.captain_id,'auto',true);

  insert into pace_v2.orders(
    customer_user_id,customer_email,customer_name,currency,subtotal_cents,
    tax_rate_bps,customer_fee_rate_bps,taxes_cents,fees_cents,total_cents,
    payment_status,paid_at,fulfillment_status
  ) values(
    fixture.customer_user_id,
    'customer-fixture+'||replace(fixture.customer_user_id::text,'-','')||'@example.invalid',
    'Rollback Customer','USD',1000,0,0,0,0,1000,'paid',now(),'booked'
  ) returning id into v_primary_order_id;
  insert into pace_v2.bookings(
    id,order_id,departure_id,route_id,customer_name,seats,status,currency,
    unit_price_cents,total_price_cents,paid_at
  ) values(
    fixture.booking_id,v_primary_order_id,fixture.outbound_id,v_primary_route_id,
    'Rollback Customer',1,'confirmed','USD',1000,1000,now()
  );
  insert into pace_v2.booking_allocations(
    booking_id,vehicle_consideration_id,departure_id,seats,unit_price_cents,status
  ) values(fixture.booking_id,v_primary_consideration_id,fixture.outbound_id,1,1000,'confirmed');

  v_second_vehicle_id:=gen_random_uuid();
  v_second_vehicle_type_id:=v_primary_vehicle_type_id;
  insert into pace_v2.vehicles(
    id,operator_id,vehicle_type_id,name,description,picture_url,active,
    capacity_seats,capacity_source,capacity_verified_at,default_min_seats,
    default_max_seats,default_min_revenue_cents,
    default_min_value_threshold_ratio,default_max_seat_discount_bps
  )
  select v_second_vehicle_id,vehicle.operator_id,vehicle.vehicle_type_id,
    'Rollback fixture '||left(replace(v_second_vehicle_id::text,'-',''),12),
    vehicle.description,vehicle.picture_url,true,vehicle.capacity_seats,
    vehicle.capacity_source,vehicle.capacity_verified_at,vehicle.default_min_seats,
    vehicle.default_max_seats,vehicle.default_min_revenue_cents,
    vehicle.default_min_value_threshold_ratio,vehicle.default_max_seat_discount_bps
  from pace_v2.vehicles vehicle where vehicle.id=v_primary_vehicle_id;

  select * into source_allocation from pace_v2.confirmed_allocations
  where id=fixture.allocation_id;
  select * into primary_consideration from pace_v2.vehicle_considerations
  where id=v_primary_consideration_id;
  select * into primary_offer from pace_v2.vehicle_route_offers
  where id=primary_consideration.vehicle_route_offer_id;
  insert into pace_v2.vehicle_route_offers
  select (jsonb_populate_record(
    null::pace_v2.vehicle_route_offers,
    to_jsonb(primary_offer)||jsonb_build_object(
      'id',v_second_offer_id,'vehicle_id',v_second_vehicle_id,
      'route_id',v_primary_route_id,'service_id',v_primary_service_id
    )
  )).*;

  insert into pace_v2.vehicle_considerations(
    departure_id,vehicle_route_offer_id,vehicle_id,operator_id,status,
    normal_min_seats,max_seats,min_revenue_cents,min_value_threshold_ratio,
    normal_base_seat_price_cents,assigned_seats,assigned_revenue_cents,
    minimum_achieved_at,discount_activated_at,opened_at,under_consideration_at,
    withdrawal_deadline_ts,withdrawn_at,withdrawal_reason,t72_discarded_at,
    quality_score_snapshot,effective_commission_bps,effective_commission_source,
    engine_version,post_min_discount_enabled,post_min_discount_bps,
    commercial_snapshot_locked_at,commercial_snapshot_source,
    below_minimum_operation_mode
  ) values(
    fixture.outbound_id,v_second_offer_id,
    v_second_vehicle_id,v_primary_operator_id,'eligible',
    primary_consideration.normal_min_seats,primary_consideration.max_seats,
    primary_consideration.min_revenue_cents,primary_consideration.min_value_threshold_ratio,
    primary_consideration.normal_base_seat_price_cents,0,0,
    null,null,now(),now(),primary_consideration.withdrawal_deadline_ts,
    null,null,null,primary_consideration.quality_score_snapshot,
    primary_consideration.effective_commission_bps,
    primary_consideration.effective_commission_source,
    primary_consideration.engine_version,primary_consideration.post_min_discount_enabled,
    primary_consideration.post_min_discount_bps,null,
    primary_consideration.commercial_snapshot_source,
    primary_consideration.below_minimum_operation_mode
  ) returning id into v_second_consideration_id;

  insert into pace_v2.captains(operator_id,first_name,last_name,email,auth_user_id,active)
  values(
    v_primary_operator_id,'Rollback','Captain Two',
    'captain-fixture+'||replace(fixture.captain_2_user_id::text,'-','')||'@example.invalid',
    fixture.captain_2_user_id,true
  ) returning id into v_second_captain_id;
  insert into pace_v2.captain_vehicle_types(captain_id,vehicle_type_id,active)
  values(v_second_captain_id,v_second_vehicle_type_id,true);

  insert into pace_v2.captains(operator_id,first_name,last_name,email,auth_user_id,active)
  values(
    v_primary_operator_id,'Rollback','Other Captain',
    'captain-fixture+'||replace(fixture.other_captain_user_id::text,'-','')||'@example.invalid',
    fixture.other_captain_user_id,true
  ) returning id into v_other_captain_id;

  insert into pace_v2.confirmed_allocations(
    departure_id,vehicle_id,operator_id,consideration_id,confirmed_at,confirmed_by,
    operator_journey_value_cents,effective_commission_bps,pace_shuttles_commission_cents,
    operator_net_before_adjustments_cents,status,completed_at,created_at
  ) values(
    fixture.outbound_id,v_second_vehicle_id,v_primary_operator_id,v_second_consideration_id,
    now(),source_allocation.confirmed_by,source_allocation.operator_journey_value_cents,
    source_allocation.effective_commission_bps,source_allocation.pace_shuttles_commission_cents,
    source_allocation.operator_net_before_adjustments_cents,'confirmed',null,now()
  ) returning id into v_second_allocation_id;
  insert into pace_v2.captain_assignments(confirmed_allocation_id,captain_id,assignment_source,active)
  values(v_second_allocation_id,v_second_captain_id,'auto',true)
  returning id into v_second_assignment_id;

  v_second_booking_id:=gen_random_uuid();
  insert into pace_v2.orders(
    customer_user_id,customer_email,customer_name,currency,subtotal_cents,
    tax_rate_bps,customer_fee_rate_bps,taxes_cents,fees_cents,total_cents,
    payment_status,paid_at,fulfillment_status
  ) values(
    fixture.customer_user_id,
    'customer-fixture+'||replace(fixture.customer_user_id::text,'-','')||'@example.invalid',
    'Rollback Customer Two','USD',1000,0,0,0,0,1000,'paid',now(),'booked'
  ) returning id into v_second_order_id;
  insert into pace_v2.bookings(
    id,order_id,departure_id,route_id,customer_name,seats,status,currency,
    unit_price_cents,total_price_cents,paid_at
  ) values(
    v_second_booking_id,v_second_order_id,fixture.outbound_id,v_primary_route_id,
    'Rollback Customer Two',1,'confirmed','USD',1000,1000,now()
  );
  insert into pace_v2.booking_allocations(
    booking_id,vehicle_consideration_id,departure_id,seats,unit_price_cents,status
  ) values(v_second_booking_id,v_second_consideration_id,fixture.outbound_id,1,1000,'confirmed');

  update captain_today_fixture set
    allocation_2_id=v_second_allocation_id,
    allocation_2_original_departure_id=fixture.outbound_id,
    consideration_2_id=v_second_consideration_id,
    assignment_2_id=v_second_assignment_id,
    captain_2_id=v_second_captain_id,
    booking_2_id=v_second_booking_id;
end
$captain_today_seed_independent_identities$;

do $captain_today_fixture_required$
begin
  if not exists(select 1 from captain_today_fixture) then
    raise exception 'fixture: clean allocation, booking, operator and fixture captain identity candidates required';
  end if;
  if exists(select 1 from captain_today_fixture where allocation_2_id is null) then
    raise exception 'fixture: two allocations and captains with compatible operator/vehicle eligibility and an unopened party thread required';
  end if;
end
$captain_today_fixture_required$;

update pace_v2.countries country set timezone='UTC'
from captain_today_fixture f
join pace_v2.departures d on d.id=f.outbound_id
join pace_v2.routes r on r.id=d.route_id
where country.id=r.country_id;

update pace_v2.departures d
set scheduled_departure_ts=date_trunc('day',now())+interval '8 hours',
    scheduled_arrival_ts=greatest(date_trunc('day',now())+interval '10 hours',now()+interval '1 hour'),
    local_departure_date=(now() at time zone 'UTC')::date,
    actual_departure_ts=null,actual_arrival_ts=null
from captain_today_fixture f where d.id=f.outbound_id;

insert into pace_v2.departures(
  id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
  trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial
)
select f.return_id,d.service_id,d.route_id,
  date_trunc('day',now())+interval '13 hours',date_trunc('day',now())+interval '15 hours',
  'UTC',(now() at time zone 'UTC')::date,
  date_trunc('day',now())-interval '59 hours',date_trunc('day',now())-interval '11 hours',
  d.status,false
from captain_today_fixture f
join pace_v2.departures d on d.id=f.outbound_id;

do $$ declare v_pair_id uuid; begin
  perform set_config('pace_v2.journey_pair_mutation_authorized','on',true);
  insert into pace_v2.journey_pairs(outbound_departure_id,return_departure_id)
  select outbound_id,return_id from captain_today_fixture
  returning id into v_pair_id;
  update captain_today_fixture set pair_id=v_pair_id;
  update pace_v2.departures d
  set journey_pair_id=f.pair_id,
      leg_number=case when d.id=f.outbound_id then 1 else 2 end
  from captain_today_fixture f where d.id in(f.outbound_id,f.return_id);
  perform set_config('pace_v2.journey_pair_mutation_authorized','off',true);
end $$;
set constraints all immediate;
set constraints all deferred;

-- A departure may legitimately have multiple confirmed vehicle allocations.
-- Both duties share the paired service legs but retain separate crew evidence
-- and booking-allocation manifests.
update pace_v2.confirmed_allocations ca set departure_id=f.outbound_id
from captain_today_fixture f where ca.id=f.allocation_2_id;
update pace_v2.bookings booking set departure_id=f.outbound_id,route_id=departure.route_id
from captain_today_fixture f
join pace_v2.departures departure on departure.id=f.outbound_id
where booking.id=f.booking_2_id;

-- The fixture reuses one rollback-only live departure as its source. Retire
-- any other confirmed allocations on that row inside this transaction so the
-- active lifecycle set is exactly the two allocations exercised below. This
-- preserves the legacy rule that a departure completes only after its final
-- confirmed allocation; the outer rollback restores every source row.
do $captain_today_confirmed_allocation_scope$
declare v_confirmed_count integer;
begin
  update pace_v2.confirmed_allocations allocation
  set status='completed',completed_at=coalesce(allocation.completed_at,clock_timestamp())
  from captain_today_fixture fixture
  where allocation.departure_id=fixture.outbound_id
    and allocation.status='confirmed'
    and allocation.id not in(fixture.allocation_id,fixture.allocation_2_id);

  select count(*) into v_confirmed_count
  from pace_v2.confirmed_allocations allocation
  join captain_today_fixture fixture on allocation.departure_id=fixture.outbound_id
  where allocation.status='confirmed';
  if v_confirmed_count<>2 then
    raise exception 'fixture: paired lifecycle requires exactly two controlled confirmed allocations';
  end if;
end
$captain_today_confirmed_allocation_scope$;

-- Resource eligibility spans the full shared duty. Each probe rolls back its
-- temporary conflict so the state-machine fixture remains reusable below.
do $$ declare v_rejected boolean:=false; v_allocation_id uuid; begin
  begin
    insert into pace_v2.vehicle_availability_exceptions(
      vehicle_id,start_ts,end_ts,reason_code,reason_note
    )
    select allocation.vehicle_id,return_leg.scheduled_departure_ts,
      return_leg.scheduled_arrival_ts,'operator_unavailable','Legacy preflight conflict'
    from captain_today_fixture fixture
    join pace_v2.confirmed_allocations allocation on allocation.id=fixture.allocation_id
    join pace_v2.departures return_leg on return_leg.id=fixture.return_id;
    begin
      for v_allocation_id in
        select allocation.id from pace_v2.confirmed_allocations allocation
        where allocation.status='confirmed' order by allocation.id
      loop
        perform pace_v2.assert_confirmed_allocation_has_eligible_captain(v_allocation_id);
      end loop;
    exception when others then
      v_rejected:=position('confirmed allocation resource window conflicts' in sqlerrm)>0;
    end;
    if not v_rejected then
      raise exception 'legacy conflicting confirmed allocation passed migration resource preflight';
    end if;
    raise exception 'rollback legacy allocation resource preflight probe';
  exception when raise_exception then
    if sqlerrm<>'rollback legacy allocation resource preflight probe' then raise; end if;
  end;
end $$;

do $$ declare v_rejected boolean:=false; begin
  begin
    insert into pace_v2.vehicle_availability_exceptions(
      vehicle_id,start_ts,end_ts,reason_code,reason_note
    )
    select allocation.vehicle_id,return_leg.scheduled_departure_ts,
      return_leg.scheduled_arrival_ts,'operator_unavailable','Leg 2 fixture conflict'
    from captain_today_fixture fixture
    join pace_v2.confirmed_allocations allocation on allocation.id=fixture.allocation_id
    join pace_v2.departures return_leg on return_leg.id=fixture.return_id;
    begin
      set constraints pace_v2.vehicle_availability_preserves_allocated_resources immediate;
    exception when others then
      v_rejected:=position('confirmed allocation resource window conflicts' in sqlerrm)>0;
    end;
    if not v_rejected then
      raise exception 'Leg 2 vehicle unavailability remained eligible; availability dependency mutation did not revalidate a confirmed allocation';
    end if;
    raise exception 'rollback Leg 2 vehicle availability probe';
  exception when raise_exception then
    if sqlerrm<>'rollback Leg 2 vehicle availability probe' then raise; end if;
  end;
end $$;

do $$ declare v_rejected boolean:=false; begin
  begin
    update pace_v2.route_vehicle_types eligibility set active=false
    from captain_today_fixture fixture
    join pace_v2.confirmed_allocations allocation on allocation.id=fixture.allocation_id
    join pace_v2.vehicles vehicle on vehicle.id=allocation.vehicle_id
    join pace_v2.departures return_leg on return_leg.id=fixture.return_id
    where eligibility.route_id=return_leg.route_id
      and eligibility.vehicle_type_id=vehicle.vehicle_type_id
      and eligibility.active;
    begin
      set constraints pace_v2.route_vehicle_type_preserves_allocated_resources immediate;
    exception when others then
      v_rejected:=position('confirmed allocation resource window conflicts' in sqlerrm)>0;
    end;
    if not v_rejected then
      raise exception 'route eligibility dependency mutation did not revalidate a confirmed allocation';
    end if;
    raise exception 'rollback return route eligibility dependency probe';
  exception when raise_exception then
    if sqlerrm<>'rollback return route eligibility dependency probe' then raise; end if;
  end;
end $$;

do $$ declare v_rejected boolean:=false; v_unsupported_route_id uuid:=gen_random_uuid(); begin
  begin
    insert into pace_v2.routes(
      id,route_name,name,trip_timezone,pickup_id,destination_id,country_id,is_active,
      market_id,region_id,locality_id,approx_duration_mins,booking_lead_time_hours,t72_hours,t24_hours
    )
    select v_unsupported_route_id,'Unsupported return route','Unsupported return route',
      route.trip_timezone,route.pickup_id,route.destination_id,route.country_id,true,
      route.market_id,route.region_id,route.locality_id,route.approx_duration_mins,
      route.booking_lead_time_hours,route.t72_hours,route.t24_hours
    from captain_today_fixture fixture
    join pace_v2.departures outbound on outbound.id=fixture.outbound_id
    join pace_v2.routes route on route.id=outbound.route_id;
    update pace_v2.departures return_leg set route_id=v_unsupported_route_id
    from captain_today_fixture fixture where return_leg.id=fixture.return_id;
    begin
      perform pace_v2.assert_confirmed_allocation_has_eligible_captain(
        (select allocation_id from captain_today_fixture)
      );
    exception when others then
      v_rejected:=position('confirmed allocation resource window conflicts' in sqlerrm)>0;
    end;
    if not v_rejected then raise exception 'vehicle type unsupported on the return route remained public'; end if;
    raise exception 'rollback unsupported return route probe';
  exception when raise_exception then
    if sqlerrm<>'rollback unsupported return route probe' then raise; end if;
  end;
end $$;

do $$ begin
  begin
    update pace_v2.captain_assignments assignment set captain_id=fixture.captain_id
    from captain_today_fixture fixture where assignment.id=fixture.assignment_2_id;
    if exists(
      select 1 from captain_today_fixture fixture
      join lateral pace_v2.pick_default_captain(fixture.allocation_id) picked on true
      where picked.captain_id=fixture.captain_id
    ) then raise exception 'captain overlap during Leg 2 remained eligible'; end if;
    raise exception 'rollback captain Leg 2 overlap probe';
  exception when raise_exception then
    if sqlerrm<>'rollback captain Leg 2 overlap probe' then raise; end if;
  end;
end $$;

do $one_way_message_close_contract$
declare
  v_one_way_departure_id uuid:=gen_random_uuid();
  v_one_way_allocation_id uuid;
  v_expected timestamptz;
begin
  if pace_v2.journey_message_closes_at((select allocation_id from captain_today_fixture))<=now() then
    raise exception 'paired messaging closed before delayed Leg 2 completion';
  end if;
  begin
    -- Keep the protected paired duty intact. This fresh cancelled row has
    -- no pair, booking, consideration, assignment, or operation evidence and
    -- is discarded with the probe's subtransaction.
    insert into pace_v2.departures(
      id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
      trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial
    )
    select v_one_way_departure_id,outbound.service_id,outbound.route_id,
      outbound.scheduled_departure_ts+interval '1000 years',
      outbound.scheduled_arrival_ts+interval '1000 years',
      outbound.trip_timezone,outbound.local_departure_date+365250,
      outbound.t72_ts+interval '1000 years',outbound.t24_ts+interval '1000 years',
      'cancelled',true
    from captain_today_fixture fixture
    join pace_v2.departures outbound on outbound.id=fixture.outbound_id;
    insert into pace_v2.confirmed_allocations(
      departure_id,vehicle_id,operator_id,consideration_id,confirmed_at,confirmed_by,
      operator_journey_value_cents,effective_commission_bps,pace_shuttles_commission_cents,
      operator_net_before_adjustments_cents,status,completed_at,created_at
    )
    select v_one_way_departure_id,allocation.vehicle_id,allocation.operator_id,null,
      now(),allocation.confirmed_by,allocation.operator_journey_value_cents,
      allocation.effective_commission_bps,allocation.pace_shuttles_commission_cents,
      allocation.operator_net_before_adjustments_cents,'confirmed',null,now()
    from captain_today_fixture fixture
    join pace_v2.confirmed_allocations allocation on allocation.id=fixture.allocation_id
    returning id into v_one_way_allocation_id;
    select coalesce(departure.actual_arrival_ts+interval '4 hours',
      departure.scheduled_arrival_ts+interval '12 hours')
      into v_expected
    from pace_v2.departures departure where departure.id=v_one_way_departure_id;
    if pace_v2.journey_message_closes_at(v_one_way_allocation_id) is distinct from v_expected then
      raise exception 'one-way messaging close behavior changed';
    end if;
    raise exception 'rollback one-way messaging close probe';
  exception when raise_exception then
    if sqlerrm<>'rollback one-way messaging close probe' then raise; end if;
  end;
end
$one_way_message_close_contract$;

update captain_today_fixture f
set voyage_log_count=(select count(*) from pace_v2.voyage_logs vl where vl.confirmed_allocation_id=f.allocation_id),
    completed_voyage_count=(select count(*) from pace_v2.voyage_logs vl where vl.confirmed_allocation_id=f.allocation_id and vl.actual_arrival_ts is not null),
    feedback_count=(select count(*) from pace_v2.notifications n where n.booking_id=f.booking_id and n.template_code='post_journey_feedback'),
    completed_voyage_2_count=(select count(*) from pace_v2.voyage_logs vl where vl.confirmed_allocation_id=f.allocation_2_id and vl.actual_arrival_ts is not null),
    feedback_2_count=(select count(*) from pace_v2.notifications n where n.booking_id=f.booking_2_id and n.template_code='post_journey_feedback');

insert into pace_v2.journey_conversations(booking_id,confirmed_allocation_id,status,opened_at)
select booking_id,allocation_id,'open',clock_timestamp() from captain_today_fixture
on conflict(booking_id,confirmed_allocation_id) do update set status='open',opened_at=excluded.opened_at,closed_at=null;

insert into pace_v2.journey_conversation_messages(conversation_id,sender_type,sender_user_id,category,message_text)
select conversation.id,'customer',fixture.customer_user_id,'day_of_travel','Captain Today unread evidence'
from captain_today_fixture fixture
join pace_v2.journey_conversations conversation
  on conversation.booking_id=fixture.booking_id
 and conversation.confirmed_allocation_id=fixture.allocation_id;

do $captain_today_acl_contract$
declare v_view text; v_signature text; v_function oid;
begin
  foreach v_view in array array['v2_captain_today_duties','v2_captain_today_manifest'] loop
    if to_regclass('public.'||v_view) is null then raise exception 'captain Today view missing: %',v_view; end if;
    if has_table_privilege('anon','public.'||v_view,'select') then raise exception 'anonymous captain Today read remains: %',v_view; end if;
    if not has_table_privilege('authenticated','public.'||v_view,'select') then raise exception 'authenticated captain Today read missing: %',v_view; end if;
    if not coalesce((select reloptions @> array['security_invoker=true'] from pg_class where oid=('public.'||v_view)::regclass),false) then
      raise exception 'captain Today view is not security_invoker: %',v_view;
    end if;
  end loop;
  if has_table_privilege('anon','pace_v2.captain_leg_operations','select')
     or has_table_privilege('authenticated','pace_v2.captain_leg_operations','select')
     or has_table_privilege('authenticated','pace_v2.captain_leg_operations','insert')
     or has_table_privilege('authenticated','pace_v2.captain_leg_operations','update')
     or has_table_privilege('authenticated','pace_v2.captain_leg_operations','delete') then
    raise exception 'captain leg evidence table has unsafe API grants';
  end if;
  if has_table_privilege('anon','pace_v2.captain_private_message_requests','select')
     or has_table_privilege('authenticated','pace_v2.captain_private_message_requests','select')
     or has_table_privilege('authenticated','pace_v2.captain_private_message_requests','insert')
     or has_table_privilege('authenticated','pace_v2.captain_private_message_requests','update')
     or has_table_privilege('authenticated','pace_v2.captain_private_message_requests','delete') then
    raise exception 'captain private message request audit has unsafe API grants';
  end if;
  foreach v_signature in array array[
    'pace_v2.captain_today_duties()','pace_v2.captain_today_manifest()',
    'public.v2_captain_start_leg(uuid)','public.v2_captain_end_leg(uuid,text,text,text)',
    'public.v2_captain_open_party_conversation(uuid,uuid,text,text,uuid)'
  ] loop
    v_function:=to_regprocedure(v_signature);
    if v_function is null then raise exception 'captain Today function missing: %',v_signature; end if;
    if has_function_privilege('public',v_function,'execute')
       or has_function_privilege('anon',v_function,'execute')
       or not has_function_privilege('authenticated',v_function,'execute') then
      raise exception 'captain Today function grants are unsafe: %',v_signature;
    end if;
  end loop;
  foreach v_signature in array array[
    'pace_v2.prevent_paired_legacy_completion()',
    'pace_v2.lock_captain_duty_identity(uuid)',
    'pace_v2.captain_duty_recovery_deadline(uuid,uuid)',
    'pace_v2.captain_duty_recovery_expired(uuid,uuid,uuid)',
    'pace_v2.captain_duty_action_allowed(uuid,uuid,uuid,uuid,text)',
    'pace_v2.protect_captain_leg_operation_actors()'
  ] loop
    v_function:=to_regprocedure(v_signature);
    if v_function is null
       or has_function_privilege('public',v_function,'execute')
       or has_function_privilege('anon',v_function,'execute')
       or has_function_privilege('authenticated',v_function,'execute') then
      raise exception 'captain internal state-machine helper has unsafe API grants: %',v_signature;
    end if;
  end loop;
end
$captain_today_acl_contract$;

insert into pace_v2.captain_leg_operations(
  confirmed_allocation_id,departure_id,captain_assignment_id,started_at,started_by_user_id
)
select allocation_2_id,outbound_id,assignment_2_id,clock_timestamp(),captain_2_user_id
from captain_today_fixture;

select set_config('request.jwt.claim.sub',(select captain_2_user_id::text from captain_today_fixture),true);
set local role authenticated;
do $$ declare v_count integer; begin
  select count(*) into v_count from public.v2_captain_today_duties duty
  join captain_today_fixture f on duty.duty_id=f.allocation_2_id
  where duty.leg_1_started_at is not null;
  if v_count<>1 then raise exception 'two allocations on one departure shared leg evidence'; end if;
  if exists(
    select 1 from public.v2_captain_today_manifest manifest
    join captain_today_fixture f on manifest.duty_id=f.allocation_2_id
    where manifest.booking_id=f.booking_id
  ) or not exists(
    select 1 from public.v2_captain_today_manifest manifest
    join captain_today_fixture f on manifest.duty_id=f.allocation_2_id
    where manifest.booking_id=f.booking_2_id
  ) then raise exception 'captain manifest crossed confirmed allocations'; end if;
end $$;
reset role;

update pace_v2.captain_assignments assignment set captain_id=f.captain_id
from captain_today_fixture f where assignment.id=f.assignment_2_id;
select set_config('request.jwt.claim.sub',(select captain_user_id::text from captain_today_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin
  begin perform public.v2_captain_start_leg((select outbound_id from captain_today_fixture));
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'captain duty is ambiguous for departure' then
    raise exception 'ambiguous captain departure action was accepted: %',v_error;
  end if;
end $$;
reset role;
update pace_v2.captain_assignments assignment set captain_id=f.captain_2_id
from captain_today_fixture f where assignment.id=f.assignment_2_id;

-- Customer, unrelated captain and operator identities receive empty projections
-- and cannot mutate a duty. The errors are deliberately indistinguishable.
select set_config('request.jwt.claim.sub',(select customer_user_id::text from captain_today_fixture),true);
set local role authenticated;
do $$ declare v_count integer; v_error text; begin
  select count(*) into v_count from public.v2_captain_today_duties;
  select v_count+(select count(*) from public.v2_captain_today_manifest) into v_count;
  if v_count<>0 then raise exception 'customer saw a captain Today duty or manifest'; end if;
  begin perform public.v2_captain_start_leg((select outbound_id from captain_today_fixture)); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'captain assignment required' then raise exception 'customer leg denial mismatch: %',v_error; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub',(select other_captain_user_id::text from captain_today_fixture),true);
set local role authenticated;
do $$ declare v_count integer; v_error text; begin
  select count(*) into v_count from public.v2_captain_today_duties;
  select v_count+(select count(*) from public.v2_captain_today_manifest) into v_count;
  if v_count<>0 then raise exception 'other captain saw an assigned captain Today duty or manifest'; end if;
  begin perform public.v2_captain_start_leg((select return_id from captain_today_fixture)); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'captain assignment required' then raise exception 'other captain leg denial mismatch: %',v_error; end if;
  v_error:=null;
  begin perform public.v2_captain_open_party_conversation(
    (select allocation_2_id from captain_today_fixture),
    (select booking_2_id from captain_today_fixture),
    'unauthorized private message','operational',gen_random_uuid()
  ); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'journey party not assigned to captain' then
    raise exception 'unassigned captain initiated a private party thread: %',v_error;
  end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub',(select operator_user_id::text from captain_today_fixture),true);
set local role authenticated;
do $$ declare v_count integer; v_error text; begin
  select count(*) into v_count from public.v2_captain_today_duties;
  select v_count+(select count(*) from public.v2_captain_today_manifest) into v_count;
  if v_count<>0 then raise exception 'operator saw a captain Today duty or manifest'; end if;
  begin perform public.v2_captain_end_leg((select outbound_id from captain_today_fixture),'normal','',''); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'captain assignment required' then raise exception 'operator leg denial mismatch: %',v_error; end if;
end $$;
reset role;

-- Assigned captain: projection, minimal grouped manifest, strict two-leg order,
-- exact retry timestamps, and final-only integration with legacy journey completion.
do $$ declare v_error text; begin
  begin
    update pace_v2.departures departure
    set scheduled_departure_ts=date_trunc('day',now())-interval '2 hours'
    from captain_today_fixture fixture where departure.id=fixture.outbound_id;
    perform set_config('request.jwt.claim.sub',
      (select captain_user_id::text from captain_today_fixture),true);
    begin
      perform public.v2_captain_start_leg((select outbound_id from captain_today_fixture));
    exception when others then v_error:=sqlerrm; end;
    if v_error is distinct from 'captain duty is not operating today' then
      raise exception 'unrelated historical duty action was accepted: %',v_error;
    end if;
    raise exception 'rollback historical duty action probe';
  exception when raise_exception then
    if sqlerrm<>'rollback historical duty action probe' then raise; end if;
  end;
end $$;
select set_config('request.jwt.claim.sub',(select captain_user_id::text from captain_today_fixture),true);
do $$ begin
  begin
    update pace_v2.bookings booking set customer_name=''
    from captain_today_fixture fixture where booking.id=fixture.booking_id;
    delete from pace_v2.passengers passenger using captain_today_fixture fixture
    where passenger.booking_id=fixture.booking_id;
    insert into pace_v2.passengers(booking_id,first_name,last_name,age_group)
    select booking_id,'Alpha','Zulu','adult' from captain_today_fixture
    union all
    select booking_id,'Bravo','Able','adult' from captain_today_fixture;
    if exists(
      select 1 from pace_v2.captain_today_manifest() manifest
      join captain_today_fixture fixture
        on fixture.allocation_id=manifest.duty_id and fixture.booking_id=manifest.booking_id
      where manifest.lead_passenger_name not in('Alpha Zulu','Bravo Able')
    ) then raise exception 'manifest fallback combined names from different passengers'; end if;
    raise exception 'rollback manifest passenger-row probe';
  exception when raise_exception then
    if sqlerrm<>'rollback manifest passenger-row probe' then raise; end if;
  end;
end $$;
set local role authenticated;
do $$
declare v_count integer; v_error text; v_first timestamptz; v_retry timestamptz;
begin
  select count(*) into v_count from public.v2_captain_today_duties d
  join captain_today_fixture f on d.duty_id=f.allocation_id
  where d.leg_1_started_at is null;
  if v_count<>1 then raise exception 'assigned captain did not see exactly one Today duty'; end if;
  if not exists(
    select 1 from public.v2_captain_today_duties duty
    join captain_today_fixture fixture on fixture.allocation_id=duty.duty_id
    join pace_v2.departures departure on departure.id=fixture.outbound_id
    join pace_v2.routes route on route.id=departure.route_id
    join pace_v2.pickup_points pickup on pickup.id=route.pickup_id
    where duty.pickup_name=pickup.name
  ) then raise exception 'captain Today duty did not expose the configured pickup name'; end if;
  select count(*) into v_count from public.v2_captain_today_manifest m
  join captain_today_fixture f on m.duty_id=f.allocation_id and m.booking_id=f.booking_id;
  if v_count<>1 then raise exception 'assigned captain manifest was not grouped once for its booking'; end if;
  if not exists(
    select 1 from public.v2_captain_today_manifest manifest
    join captain_today_fixture fixture on manifest.duty_id=fixture.allocation_id and manifest.booking_id=fixture.booking_id
    where manifest.unread_count>0
  ) then raise exception 'captain manifest did not expose protected party unread count'; end if;
  if exists(
    select 1 from public.v2_captain_today_manifest m
    join captain_today_fixture f on m.duty_id=f.allocation_id and m.booking_id=f.booking_2_id
  ) then raise exception 'captain manifest crossed confirmed allocations'; end if;
  if exists(
    select 1 from public.v2_captain_today_manifest m
    join captain_today_fixture f on m.booking_id=f.booking_id
    where jsonb_path_exists(m.passengers,'$[*].email') or jsonb_path_exists(m.passengers,'$[*].phone')
  ) then raise exception 'manifest exposed customer email or phone'; end if;

  begin perform public.v2_captain_end_leg((select outbound_id from captain_today_fixture),'normal','',''); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'leg transition out of order' then raise exception 'end leg 1 before start was accepted: %',v_error; end if;
  v_error:=null;
  begin perform public.v2_captain_start_leg((select return_id from captain_today_fixture)); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'leg transition out of order' then raise exception 'start leg 2 before leg 1 completion was accepted: %',v_error; end if;
  v_error:=null;
  begin perform public.v2_captain_end_leg((select return_id from captain_today_fixture),'normal','',''); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'leg transition out of order' then raise exception 'end leg 2 before start was accepted: %',v_error; end if;

  v_error:=null;
  begin
    perform public.v2_captain_start_journey(
      p_captain_assignment_id=>(select assignment_id from captain_today_fixture)
    );
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'paired duty must be started with v2_captain_start_leg' then
    raise exception 'legacy start bypass opened a paired duty: %',v_error;
  end if;

  v_first:=public.v2_captain_start_leg((select outbound_id from captain_today_fixture));
  v_retry:=public.v2_captain_start_leg((select outbound_id from captain_today_fixture));
  if v_retry is distinct from v_first then raise exception 'start leg 1 retry changed its timestamp'; end if;
  update captain_today_fixture set start_1=v_first;
  v_error:=null;
  begin perform public.v2_captain_end_leg((select outbound_id from captain_today_fixture),null,'',''); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'invalid completion state' then raise exception 'null completion state was accepted: %',v_error; end if;
  v_error:=null;
  begin perform public.v2_captain_end_leg((select outbound_id from captain_today_fixture),'incident','',' '); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'incident summary required' then raise exception 'blank incident summary was accepted: %',v_error; end if;

  -- An incident-ended first leg is terminal. Exercise both the transition and
  -- evidence immutability in a subtransaction, then roll the probe back so the
  -- normal two-leg fixture can continue.
  begin
    perform public.v2_captain_end_leg(
      (select outbound_id from captain_today_fixture),'incident','terminal incident','fixture escalation required'
    );
    v_error:=null;
    begin perform public.v2_captain_start_leg((select return_id from captain_today_fixture));
    exception when others then v_error:=sqlerrm; end;
    if v_error is distinct from 'incident-ended duty cannot start another leg; escalate to Site Admin' then
      raise exception 'incident-ended Leg 1 allowed Leg 2 to start: %',v_error;
    end if;
    v_error:=null;
    begin perform public.v2_captain_end_leg(
      (select outbound_id from captain_today_fixture),'normal','terminal incident',null
    ); exception when others then v_error:=sqlerrm; end;
    if v_error is distinct from 'leg completion evidence already recorded' then
      raise exception 'incident completion was rewritten as normal: %',v_error;
    end if;
    if not exists(
      select 1 from public.v2_captain_today_duties duty
      join captain_today_fixture fixture on fixture.allocation_id=duty.duty_id
      where duty.leg_1_completion_state='incident' and duty.duty_state='incident'
    ) then raise exception 'incident completion was not projected as terminal for Leg 1'; end if;
    raise exception 'rollback incident terminal probe';
  exception when raise_exception then
    if sqlerrm<>'rollback incident terminal probe' then raise; end if;
  end;

  v_error:=null;
  begin
    perform public.v2_captain_end_leg((select outbound_id from captain_today_fixture),'normal','  leg one complete  ','incident text');
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'normal completion cannot include an incident summary' then
    raise exception 'direct normal completion with an incident summary was accepted: %',v_error;
  end if;
  v_first:=public.v2_captain_end_leg((select outbound_id from captain_today_fixture),'normal','  leg one complete  ','   ');
  if exists(
    select 1 from public.v2_captain_today_duties duty
    join captain_today_fixture fixture on fixture.allocation_id=duty.duty_id
    where duty.leg_1_incident_summary is not null
  ) then raise exception 'blank normal summary was not canonicalized to null';end if;
  v_retry:=public.v2_captain_end_leg((select outbound_id from captain_today_fixture),'normal','  leg one complete  ',null);
  if v_retry is distinct from v_first then raise exception 'end leg 1 retry changed its timestamp; normal completion retry did not treat blank summary forms canonically'; end if;
  update captain_today_fixture set end_1=v_first;
  v_error:=null;
  begin perform public.v2_captain_end_leg((select outbound_id from captain_today_fixture),'normal','leg one complete',''); exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'leg completion evidence already recorded' then raise exception 'non-exact end retry overwrote evidence: %',v_error; end if;
  v_error:=null;
  begin
    perform public.v2_captain_complete_journey(
      p_captain_assignment_id=>(select assignment_id from captain_today_fixture),
      p_completed_normally=>true,p_captain_notes=>'legacy bypass',
      p_incident_flag=>false,p_incident_summary=>''
    );
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'paired duty must be completed with v2_captain_end_leg' then
    raise exception 'legacy completion bypass closed a paired duty before leg 2: %',v_error;
  end if;
end $$;
reset role;

-- A missed return remains captain-actionable for one bounded recovery day,
-- not forever. This probe moves both scheduled arrivals beyond that ceiling
-- and rolls the schedule back after checking projection and RPC behavior.
do $$ declare v_error text; begin
  begin
    update pace_v2.departures departure
    set scheduled_departure_ts=date_trunc('day',now())-interval '4 days',
        scheduled_arrival_ts=date_trunc('day',now())-interval '4 days'+interval '2 hours',
        local_departure_date=(date_trunc('day',now())-interval '4 days')::date
    from captain_today_fixture fixture where departure.id=fixture.outbound_id;
    update pace_v2.departures departure
    set scheduled_departure_ts=date_trunc('day',now())-interval '3 days',
        scheduled_arrival_ts=date_trunc('day',now())-interval '3 days'+interval '2 hours',
        local_departure_date=(date_trunc('day',now())-interval '3 days')::date
    from captain_today_fixture fixture where departure.id=fixture.return_id;
    perform set_config('request.jwt.claim.sub',
      (select captain_user_id::text from captain_today_fixture),true);
    if exists(
      select 1 from pace_v2.captain_today_duties() duty
      join captain_today_fixture fixture on fixture.allocation_id=duty.duty_id
    ) then raise exception 'stale started paired duty remained in Today'; end if;
    begin
      perform public.v2_captain_start_leg((select return_id from captain_today_fixture));
    exception when others then v_error:=sqlerrm; end;
    if v_error is distinct from 'captain duty recovery window expired; escalate to Site Admin' then
      raise exception 'stale started paired duty action did not require Site Admin escalation: %',v_error;
    end if;
    raise exception 'rollback stale paired duty recovery probe';
  exception when raise_exception then
    if sqlerrm<>'rollback stale paired duty recovery probe' then raise; end if;
  end;
end $$;

do $$ declare v_error text; begin
  begin
    update pace_v2.departures departure set actual_arrival_ts=clock_timestamp()
    from captain_today_fixture f where departure.id=f.outbound_id;
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'paired duty must be completed with v2_captain_end_leg' then
    raise exception 'direct paired departure completion was accepted: %',v_error;
  end if;

  v_error:=null;
  begin
    update pace_v2.voyage_logs voyage set actual_arrival_ts=clock_timestamp()
    from captain_today_fixture f where voyage.confirmed_allocation_id=f.allocation_id;
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'paired duty must be completed with v2_captain_end_leg' then
    raise exception 'direct paired voyage completion was accepted: %',v_error;
  end if;

  v_error:=null;
  begin
    update pace_v2.departures departure
    set journey_pair_id=null,leg_number=null,
        actual_departure_ts=clock_timestamp(),actual_arrival_ts=clock_timestamp()
    from captain_today_fixture f where departure.id=f.outbound_id;
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'return journey cannot be removed after bookings, allocations or operation evidence exist' then
    raise exception 'combined unpair and completion was accepted: %',v_error;
  end if;
end $$;

do $$ begin
  if exists(
    select 1 from captain_today_fixture f join pace_v2.departures d on d.id=f.outbound_id
    where d.actual_arrival_ts is not null
       or (select count(*) from pace_v2.notifications n where n.booking_id=f.booking_id and n.template_code='post_journey_feedback')<>f.feedback_count
  ) then raise exception 'end leg 1 triggered whole-journey completion, settlement or feedback; legacy completion bypass changed settlement or feedback evidence'; end if;
end $$;

-- The first allocation to finish becomes allocation-complete, but must not
-- stamp shared departure completion or make either allocation's post-duty
-- communications eligible. The shared outbound advisory lock serializes this
-- with the final allocation below.
select set_config('request.jwt.claim.sub',(select captain_2_user_id::text from captain_today_fixture),true);
set local role authenticated;
do $$ declare v_first timestamptz; v_retry timestamptz; v_conversation_id uuid; v_retried_conversation_id uuid; v_request_id uuid:=gen_random_uuid(); v_error text; begin
  v_first:=public.v2_captain_end_leg(
    (select outbound_id from captain_today_fixture),'normal','allocation two leg one complete',null
  );
  v_retry:=public.v2_captain_start_leg((select return_id from captain_today_fixture));
  if v_retry is null then raise exception 'allocation two Leg 2 did not start'; end if;
  v_first:=public.v2_captain_end_leg(
    (select return_id from captain_today_fixture),'normal','allocation two final leg complete',null
  );
  v_retry:=public.v2_captain_end_leg(
    (select return_id from captain_today_fixture),'normal','allocation two final leg complete',null
  );
  if v_retry is distinct from v_first then
    raise exception 'first allocation final-leg retry changed its timestamp';
  end if;
  update captain_today_fixture set end_2_allocation_2=v_first;
  if not exists(
    select 1 from public.v2_captain_today_duties duty
    join captain_today_fixture fixture on fixture.allocation_2_id=duty.duty_id
    where duty.leg_2_completion_state='normal' and duty.duty_state='completed'
  ) then raise exception 'first allocation did not become allocation-complete'; end if;

  if exists(
    select 1 from public.v2_captain_my_journey_conversations conversation
    join captain_today_fixture fixture
      on fixture.booking_2_id=conversation.booking_id
     and fixture.allocation_2_id=conversation.confirmed_allocation_id
  ) then raise exception 'captain private-thread fixture unexpectedly had an existing conversation'; end if;
  v_conversation_id:=public.v2_captain_open_party_conversation(
    (select allocation_2_id from captain_today_fixture),
    (select booking_2_id from captain_today_fixture),
    'Captain initiated private thread','operational',v_request_id
  );
  if not exists(
    select 1 from public.v2_captain_my_journey_conversations conversation
    join public.v2_captain_my_journey_messages message
      on message.conversation_id=conversation.id
    join captain_today_fixture fixture
      on fixture.booking_2_id=conversation.booking_id
     and fixture.allocation_2_id=conversation.confirmed_allocation_id
    where conversation.id=v_conversation_id
      and conversation.status='open' and conversation.closed_at is null
      and message.sender_type='captain'
      and message.category='operational'
      and message.message_text='Captain initiated private thread'
  ) then raise exception 'captain could not initiate a private thread without an existing conversation'; end if;

  v_retried_conversation_id:=public.v2_captain_open_party_conversation(
    (select allocation_2_id from captain_today_fixture),
    (select booking_2_id from captain_today_fixture),
    'Captain initiated private thread','operational',v_request_id
  );
  if v_retried_conversation_id is distinct from v_conversation_id or (
    select count(*)
    from public.v2_captain_my_journey_messages message
    where message.conversation_id=v_conversation_id
      and message.message_text='Captain initiated private thread'
  )<>1 then raise exception 'private thread retry duplicated the first message'; end if;

  begin
    perform public.v2_captain_open_party_conversation(
      (select allocation_2_id from captain_today_fixture),
      (select booking_2_id from captain_today_fixture),
      'Changed stale request payload','operational',v_request_id
    );
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'private message request belongs to another captain, allocation, booking or payload' then
    raise exception 'stale private thread request was accepted for changed payload: %',v_error;
  end if;
  update captain_today_fixture
  set private_request_id=v_request_id,private_conversation_id=v_conversation_id;
end $$;
reset role;

do $$ begin
  if not exists(
    select 1 from pace_v2.journey_conversations conversation
    join pace_v2.journey_conversation_messages message
      on message.conversation_id=conversation.id
    join captain_today_fixture fixture
      on fixture.private_conversation_id=conversation.id
     and fixture.booking_2_id=conversation.booking_id
     and fixture.allocation_2_id=conversation.confirmed_allocation_id
    where message.sender_type='captain'
      and message.sender_user_id=fixture.captain_2_user_id
      and message.category='operational'
      and message.message_text='Captain initiated private thread'
  ) then raise exception 'captain private thread actor or relational identity was not persisted'; end if;
end $$;

-- Completed operation evidence remains pinned to the actor's original
-- assignment. Replacing that assignment must not make the later all-allocation
-- integration silently omit this allocation.
do $$ declare v_original_assignment_id uuid; v_replacement_assignment_id uuid; begin
  select assignment_2_id into v_original_assignment_id from captain_today_fixture;
  update pace_v2.captain_assignments assignment set active=false
  where assignment.id=v_original_assignment_id;
  insert into pace_v2.captain_assignments(confirmed_allocation_id,captain_id,active)
  select allocation_2_id,captain_2_id,true from captain_today_fixture
  returning id into v_replacement_assignment_id;
  update captain_today_fixture
  set original_assignment_2_id=v_original_assignment_id,
      assignment_2_id=v_replacement_assignment_id;
  set constraints all immediate;
  if not exists(
    select 1
    from captain_today_fixture fixture
    join pace_v2.captain_leg_operations operation
      on operation.confirmed_allocation_id=fixture.allocation_2_id
     and operation.departure_id=fixture.return_id
     and operation.captain_assignment_id=fixture.original_assignment_2_id
     and operation.ended_at is not null
    join pace_v2.captain_assignments original_assignment
      on original_assignment.id=operation.captain_assignment_id
     and not original_assignment.active
    join pace_v2.captain_assignments replacement_assignment
      on replacement_assignment.id=fixture.assignment_2_id
     and replacement_assignment.active
  ) then raise exception 'fixture did not replace the completed operation original assignment'; end if;
end $$;
set constraints all deferred;

-- Make the clock-dependent window boundary deterministic without changing the
-- completed request. Exact owner/payload replay must return before this helper;
-- a new request would still be rejected by the forced-closed window.
create or replace function pace_v2.is_journey_message_window_open(p_confirmed_allocation_id uuid,p_as_of timestamptz)
returns boolean language sql stable set search_path=pace_v2,public as $$ select false $$;
select set_config('request.jwt.claim.sub',(select other_captain_user_id::text from captain_today_fixture),true);
set local role authenticated;
do $$ declare v_error text; begin
  begin
    perform public.v2_captain_open_party_conversation(
      (select allocation_2_id from captain_today_fixture),
      (select booking_2_id from captain_today_fixture),
      'Captain initiated private thread','operational',
      (select private_request_id from captain_today_fixture)
    );
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'private message request belongs to another captain, allocation, booking or payload' then
    raise exception 'another caller replayed a completed private thread request after window close: %',v_error;
  end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub',(select captain_2_user_id::text from captain_today_fixture),true);
set local role authenticated;
do $$ declare v_replayed uuid; begin
  v_replayed:=public.v2_captain_open_party_conversation(
    (select allocation_2_id from captain_today_fixture),
    (select booking_2_id from captain_today_fixture),
    'Captain initiated private thread','operational',
    (select private_request_id from captain_today_fixture)
  );
  if v_replayed is distinct from (select private_conversation_id from captain_today_fixture) then
    raise exception 'completed private thread retry was blocked after the messaging window closed';
  end if;
end $$;
reset role;
create or replace function pace_v2.is_journey_message_window_open(p_confirmed_allocation_id uuid,p_as_of timestamptz)
returns boolean language sql stable set search_path=pace_v2,public as $$
 select coalesce(p_as_of>=pace_v2.journey_message_opens_at(p_confirmed_allocation_id) and p_as_of<pace_v2.journey_message_closes_at(p_confirmed_allocation_id),false);
$$;

do $$ begin
  if exists(
    select 1
    from captain_today_fixture fixture
    join pace_v2.departures outbound on outbound.id=fixture.outbound_id
    where outbound.actual_arrival_ts is not null
       or (select count(*) from pace_v2.voyage_logs voyage
           where voyage.confirmed_allocation_id=fixture.allocation_2_id
             and voyage.actual_arrival_ts is not null)<>fixture.completed_voyage_2_count
       or (select count(*) from pace_v2.notifications notification
           where notification.booking_id=fixture.booking_id
             and notification.template_code='post_journey_feedback')<>fixture.feedback_count
       or (select count(*) from pace_v2.notifications notification
           where notification.booking_id=fixture.booking_2_id
             and notification.template_code='post_journey_feedback')<>fixture.feedback_2_count
       or not exists(
         select 1 from pace_v2.journey_conversations conversation
         where conversation.booking_id=fixture.booking_2_id
           and conversation.confirmed_allocation_id=fixture.allocation_2_id
           and conversation.status='open' and conversation.closed_at is null
       )
  ) then raise exception 'first allocation final leg triggered shared completion or feedback before every allocation finished'; end if;
end $$;

-- Simulate a delayed return after local midnight. The outbound's local date is
-- now yesterday, but its primary allocation began and remains unfinished.
update pace_v2.departures departure
set scheduled_departure_ts=date_trunc('day',now())-interval '2 hours',
    scheduled_arrival_ts=date_trunc('day',now())-interval '30 minutes',
    local_departure_date=(date_trunc('day',now())-interval '2 hours')::date
from captain_today_fixture fixture where departure.id=fixture.outbound_id;

select set_config('request.jwt.claim.sub',(select captain_user_id::text from captain_today_fixture),true);
set local role authenticated;
do $$ declare v_first timestamptz; v_retry timestamptz; v_error text; begin
  if not exists(
    select 1 from public.v2_captain_today_duties duty
    join captain_today_fixture fixture on fixture.allocation_id=duty.duty_id
    where duty.duty_state='awaiting_leg_2'
  ) then raise exception 'unfinished paired duty disappeared after local midnight'; end if;
  begin
    v_first:=public.v2_captain_start_leg((select return_id from captain_today_fixture));
  exception when others then v_error:=sqlerrm; end;
  if v_error is not null then
    raise exception 'overnight paired Leg 2 start was rejected: %',v_error;
  end if;
  v_retry:=public.v2_captain_start_leg((select return_id from captain_today_fixture));
  if v_retry is distinct from v_first then raise exception 'leg 2 start retry changed its timestamp'; end if;
  update captain_today_fixture set start_2=v_first;
  begin
    v_first:=public.v2_captain_end_leg((select return_id from captain_today_fixture),'incident','final leg notes','minor delay');
  exception when others then v_error:=sqlerrm; end;
  if v_error is not null then
    raise exception 'overnight paired incident completion was rejected: %',v_error;
  end if;
  perform set_config('request.jwt.claim.sub',
    (select other_captain_user_id::text from captain_today_fixture),true);
  v_error:=null;
  begin
    perform public.v2_captain_end_leg(
      (select return_id from captain_today_fixture),'incident','final leg notes','minor delay'
    );
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'captain assignment required' then
    raise exception 'completed final-leg replay by another captain was accepted: %',v_error;
  end if;
  perform set_config('request.jwt.claim.sub',
    (select captain_user_id::text from captain_today_fixture),true);
  v_retry:=public.v2_captain_end_leg((select return_id from captain_today_fixture),'incident','final leg notes','minor delay');
  if v_retry is distinct from v_first then raise exception 'end final leg retry changed its timestamp or duplicated integration'; end if;
  update captain_today_fixture set end_2=v_first;
  if exists(
    select 1 from public.v2_captain_today_duties duty
    join captain_today_fixture f on f.allocation_id=duty.duty_id
    where duty.leg_2_completion_state='incident' and duty.duty_state='incident'
  ) then raise exception 'completed overnight paired duty remained in Today'; end if;
end $$;
reset role;

-- Feedback is intentionally asynchronous. Run the protected scheduler after
-- the next-local-day boundary and repeat it to prove notification idempotency.
select public.v2_system_schedule_feedback_requests(clock_timestamp()+interval '2 days',500);
select public.v2_system_schedule_feedback_requests(clock_timestamp()+interval '2 days',500);

do $$ declare v_actual integer; v_expected integer; begin
  if exists(
    select 1 from captain_today_fixture f
    join pace_v2.confirmed_allocations allocation
      on allocation.departure_id=f.outbound_id and allocation.status='confirmed'
  ) then
    if exists(
      select 1 from captain_today_fixture f
      join pace_v2.departures d on d.id=f.outbound_id
      where d.status='completed' or d.completed_at is not null
    ) then raise exception 'shared departure completed while a confirmed allocation remained'; end if;
  else
    if exists(
      select 1 from captain_today_fixture f
      join pace_v2.departures d on d.id=f.outbound_id
      where d.status is distinct from 'completed'
    ) then raise exception 'shared departure did not complete after the final confirmed allocation'; end if;
    if exists(
      select 1 from captain_today_fixture f
      join pace_v2.departures d on d.id=f.outbound_id
      where d.completed_at is null
    ) then raise exception 'shared departure completion timestamp missing after the final confirmed allocation'; end if;
  end if;
  if not exists(
    select 1 from captain_today_fixture f
    join pace_v2.voyage_logs vl on vl.confirmed_allocation_id=f.allocation_id
    where vl.actual_arrival_ts is not null
  ) then raise exception 'canonical finalization did not record primary allocation voyage arrival'; end if;
  if not exists(
    select 1 from captain_today_fixture f
    join pace_v2.voyage_logs vl on vl.confirmed_allocation_id=f.allocation_2_id
    where vl.actual_arrival_ts is not null
  ) then raise exception 'canonical finalization did not record secondary allocation voyage arrival'; end if;
  select (select count(*) from pace_v2.voyage_logs vl
           where vl.confirmed_allocation_id=f.allocation_id and vl.actual_arrival_ts is not null),
         f.completed_voyage_count+1
    into v_actual,v_expected from captain_today_fixture f;
  if v_actual is distinct from v_expected then
    raise exception 'primary finalization completed voyage delta expected %, got %',v_expected,v_actual;
  end if;
  select (select count(*) from pace_v2.notifications n
           where n.booking_id=f.booking_id and n.template_code='post_journey_feedback'),
         f.feedback_count+1
    into v_actual,v_expected from captain_today_fixture f;
  if v_actual is distinct from v_expected then
    raise exception 'primary finalization feedback delta expected %, got %',v_expected,v_actual;
  end if;
  select (select count(*) from pace_v2.voyage_logs vl
           where vl.confirmed_allocation_id=f.allocation_2_id and vl.actual_arrival_ts is not null),
         f.completed_voyage_2_count+1
    into v_actual,v_expected from captain_today_fixture f;
  if v_actual is distinct from v_expected then
    raise exception 'secondary finalization completed voyage delta expected %, got %',v_expected,v_actual;
  end if;
  select (select count(*) from pace_v2.notifications n
           where n.booking_id=f.booking_2_id and n.template_code='post_journey_feedback'),
         f.feedback_2_count+1
    into v_actual,v_expected from captain_today_fixture f;
  if v_actual is distinct from v_expected then
    raise exception 'secondary finalization feedback delta expected %, got %',v_expected,v_actual;
  end if;
  if pace_v2.journey_message_closes_at((select allocation_id from captain_today_fixture))
       is distinct from (select end_2+interval '4 hours' from captain_today_fixture) then
    raise exception 'paired messaging did not retain the post-completion window';
  end if;
  if exists(select 1 from pace_v2.confirmed_allocations ca join captain_today_fixture f on ca.departure_id=f.return_id)
     or exists(select 1 from pace_v2.bookings b join captain_today_fixture f on b.departure_id=f.return_id)
     or exists(select 1 from pace_v2.vehicle_considerations vc join captain_today_fixture f on vc.departure_id=f.return_id)
  then raise exception 'return leg gained a duplicate commercial identity'; end if;
end $$;

-- A completed allocation that receives the scheduler's invitation must remain
-- eligible at the authenticated feedback submission boundary.
select set_config('request.jwt.claim.sub',(select customer_user_id::text from captain_today_fixture),true);
set local role authenticated;
do $$ declare v_feedback_id uuid; begin
  v_feedback_id:=public.v2_customer_submit_feedback(
    p_booking_id=>(select booking_id from captain_today_fixture),
    p_booking_experience_rating=>5,p_nps=>10,p_operator_rating=>5,
    p_captain_rating=>5,p_pickup_rating=>5,p_destination_rating=>5,
    p_went_well=>'paired completion feedback',p_could_improve=>'',
    p_testimonial_consent=>true
  );
  if v_feedback_id is null then
    raise exception 'completed paired passenger feedback submission returned no identity';
  end if;
end $$;
reset role;

do $$ begin
  if not exists(
    select 1
    from captain_today_fixture fixture
    join pace_v2.customer_feedback feedback
      on feedback.booking_id=fixture.booking_id
     and feedback.confirmed_allocation_id=fixture.allocation_id
     and feedback.submitted_by=fixture.customer_user_id
    join pace_v2.confirmed_allocations allocation
      on allocation.id=feedback.confirmed_allocation_id
     and allocation.status='completed'
    where feedback.went_well='paired completion feedback'
  ) then
    raise exception 'completed paired passenger feedback was not persisted against its allocation';
  end if;
end $$;

select set_config('request.jwt.claim.sub',(select captain_2_user_id::text from captain_today_fixture),true);
set local role authenticated;
do $$ declare v_retry timestamptz; begin
  v_retry:=public.v2_captain_end_leg(
    (select return_id from captain_today_fixture),'normal','allocation two final leg complete',null
  );
  if v_retry is distinct from (select end_2_allocation_2 from captain_today_fixture) then
    raise exception 'first allocation retry changed its completed evidence';
  end if;
end $$;
reset role;

do $$ begin
  if exists(
    select 1
    from captain_today_fixture fixture
    join pace_v2.departures outbound on outbound.id=fixture.outbound_id
    where outbound.actual_arrival_ts is null
       or (select count(*) from pace_v2.voyage_logs voyage
           where voyage.confirmed_allocation_id=fixture.allocation_id
             and voyage.actual_arrival_ts is not null)<>fixture.completed_voyage_count+1
       or (select count(*) from pace_v2.voyage_logs voyage
           where voyage.confirmed_allocation_id=fixture.allocation_2_id
             and voyage.actual_arrival_ts is not null)<>fixture.completed_voyage_2_count+1
       or (select count(*) from pace_v2.notifications notification
           where notification.booking_id=fixture.booking_id
             and notification.template_code='post_journey_feedback')<>fixture.feedback_count+1
       or (select count(*) from pace_v2.notifications notification
           where notification.booking_id=fixture.booking_2_id
             and notification.template_code='post_journey_feedback')<>fixture.feedback_2_count+1
  ) then raise exception 'first allocation retry duplicated shared completion integration; reassigned allocation finalization retry duplicated legacy evidence'; end if;
end $$;

do $$ begin
  if exists(
    select 1 from captain_today_fixture fixture
    where not exists(
      select 1 from pace_v2.captain_leg_operations operation
      where operation.confirmed_allocation_id=fixture.allocation_id
        and operation.departure_id=fixture.outbound_id
        and operation.started_by_user_id=fixture.captain_user_id
    ) or not exists(
      select 1 from pace_v2.captain_leg_operations operation
      where operation.confirmed_allocation_id=fixture.allocation_id
        and operation.departure_id=fixture.return_id
        and operation.started_by_user_id=fixture.captain_user_id
    ) or not exists(
      select 1 from pace_v2.captain_leg_operations operation
      where operation.confirmed_allocation_id=fixture.allocation_2_id
        and operation.departure_id in(fixture.outbound_id,fixture.return_id)
        and operation.started_by_user_id=fixture.captain_2_user_id
      group by operation.confirmed_allocation_id
      having count(*)=2
    )
  ) then raise exception 'captain leg start actor was not attributed to the authenticated captain'; end if;

  if exists(
    select 1 from captain_today_fixture fixture
    where not exists(
      select 1 from pace_v2.captain_leg_operations operation
      where operation.confirmed_allocation_id=fixture.allocation_id
        and operation.departure_id in(fixture.outbound_id,fixture.return_id)
        and operation.ended_by_user_id=fixture.captain_user_id
      group by operation.confirmed_allocation_id
      having count(*)=2
    ) or not exists(
      select 1 from pace_v2.captain_leg_operations operation
      where operation.confirmed_allocation_id=fixture.allocation_2_id
        and operation.departure_id in(fixture.outbound_id,fixture.return_id)
        and operation.ended_by_user_id=fixture.captain_2_user_id
      group by operation.confirmed_allocation_id
      having count(*)=2
    )
  ) then raise exception 'captain leg end actor was not attributed to the authenticated captain'; end if;
end $$;

do $$ declare v_error text; begin
  begin
    update pace_v2.captain_leg_operations operation
    set started_by_user_id=fixture.customer_user_id
    from captain_today_fixture fixture
    where operation.confirmed_allocation_id=fixture.allocation_id
      and operation.departure_id=fixture.outbound_id;
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'captain leg start actor is immutable' then
    raise exception 'captain leg start actor rewrite was accepted: %',v_error;
  end if;

  v_error:=null;
  begin
    update pace_v2.captain_leg_operations operation
    set ended_by_user_id=fixture.customer_user_id
    from captain_today_fixture fixture
    where operation.confirmed_allocation_id=fixture.allocation_id
      and operation.departure_id=fixture.return_id;
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'captain leg end actor is immutable' then
    raise exception 'captain leg end actor rewrite was accepted: %',v_error;
  end if;

  v_error:=null;
  begin
    update pace_v2.captain_leg_operations operation
    set notes=operation.notes||' rewritten'
    from captain_today_fixture fixture
    where operation.confirmed_allocation_id=fixture.allocation_id
      and operation.departure_id=fixture.return_id;
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'captain leg completion evidence is immutable' then
    raise exception 'captain leg completion evidence rewrite was accepted: %',v_error;
  end if;
end $$;

do $$ declare v_error text; begin
  begin
    update pace_v2.departures departure set actual_arrival_ts=departure.actual_arrival_ts
    from captain_today_fixture f where departure.id=f.outbound_id;
    update pace_v2.voyage_logs voyage set actual_arrival_ts=voyage.actual_arrival_ts
    from captain_today_fixture f where voyage.confirmed_allocation_id=f.allocation_id;
  exception when others then
    raise exception 'exact paired completion no-op write was rejected: %',sqlerrm;
  end;

  begin
    update pace_v2.departures departure set actual_arrival_ts=null
    from captain_today_fixture f where departure.id=f.outbound_id;
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'paired duty must be completed with v2_captain_end_leg' then
    raise exception 'paired departure completion clearing was accepted: %',v_error;
  end if;
  v_error:=null;
  begin
    update pace_v2.departures departure set actual_arrival_ts=f.end_2+interval '1 second'
    from captain_today_fixture f where departure.id=f.outbound_id;
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'paired duty must be completed with v2_captain_end_leg' then
    raise exception 'paired departure completion change was accepted: %',v_error;
  end if;
  v_error:=null;
  begin
    update pace_v2.voyage_logs voyage set actual_arrival_ts=null
    from captain_today_fixture f where voyage.confirmed_allocation_id=f.allocation_id;
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'paired duty must be completed with v2_captain_end_leg' then
    raise exception 'paired voyage completion clearing was accepted: %',v_error;
  end if;
  v_error:=null;
  begin
    update pace_v2.voyage_logs voyage set actual_arrival_ts=f.end_2+interval '1 second'
    from captain_today_fixture f where voyage.confirmed_allocation_id=f.allocation_id;
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'paired duty must be completed with v2_captain_end_leg' then
    raise exception 'paired voyage completion change was accepted: %',v_error;
  end if;
end $$;

-- Legacy journey integration owns its own arrival clock. Snapshot that evidence
-- instead of assuming it is identical to the leg-operation completion clock.
update captain_today_fixture fixture
set legacy_departure_arrival_before_retry=(
      select departure.actual_arrival_ts
      from pace_v2.departures departure
      where departure.id=fixture.outbound_id
    ),
    legacy_voyage_arrival_before_retry=(
      select voyage.actual_arrival_ts
      from pace_v2.voyage_logs voyage
      where voyage.confirmed_allocation_id=fixture.allocation_id
        and voyage.actual_arrival_ts is not null
      order by voyage.created_at desc
      limit 1
    );

select set_config('request.jwt.claim.sub',(select captain_user_id::text from captain_today_fixture),true);
set local role authenticated;
do $$ declare v_retry timestamptz; begin
  v_retry:=public.v2_captain_end_leg(
    (select return_id from captain_today_fixture),'incident','final leg notes','minor delay'
  );
  if v_retry is distinct from (select end_2 from captain_today_fixture) then
    raise exception 'completion retry changed final-leg evidence';
  end if;
end $$;
reset role;

do $$ begin
  if exists(
    select 1 from captain_today_fixture f
    join pace_v2.departures departure on departure.id=f.outbound_id
    left join lateral(
      select legacy_voyage.actual_arrival_ts
      from pace_v2.voyage_logs legacy_voyage
      where legacy_voyage.confirmed_allocation_id=f.allocation_id
        and legacy_voyage.actual_arrival_ts is not null
      order by legacy_voyage.created_at desc
      limit 1
    ) voyage on true
    where departure.actual_arrival_ts is distinct from f.legacy_departure_arrival_before_retry
       or voyage.actual_arrival_ts is distinct from f.legacy_voyage_arrival_before_retry
  ) then raise exception 'completion retry mutated legacy evidence'; end if;
end $$;

do $$ declare v_retry timestamptz; begin
  begin
    update pace_v2.departures departure
    set scheduled_departure_ts=date_trunc('day',now())-interval '4 days',
        scheduled_arrival_ts=date_trunc('day',now())-interval '4 days'+interval '2 hours'
    from captain_today_fixture fixture where departure.id=fixture.outbound_id;
    update pace_v2.departures departure
    set scheduled_departure_ts=date_trunc('day',now())-interval '3 days',
        scheduled_arrival_ts=date_trunc('day',now())-interval '3 days'+interval '2 hours'
    from captain_today_fixture fixture where departure.id=fixture.return_id;
    perform set_config('request.jwt.claim.sub',
      (select captain_user_id::text from captain_today_fixture),true);
    v_retry:=public.v2_captain_end_leg(
      (select return_id from captain_today_fixture),'incident','final leg notes','minor delay'
    );
    if v_retry is distinct from (select end_2 from captain_today_fixture) then
      raise exception 'cross-deadline exact completion retry changed evidence or failed';
    end if;
    raise exception 'rollback cross-deadline exact completion retry probe';
  exception when raise_exception then
    if sqlerrm<>'rollback cross-deadline exact completion retry probe' then raise; end if;
  end;
end $$;

do $$ declare v_definition text; begin
  select pg_get_functiondef('pace_v2.lock_captain_duty_identity(uuid)'::regprocedure)
    into v_definition;
  if position('service-return-design:' in v_definition)=0
     or position('for update' in lower(v_definition))=0
     or position('journey pair identity changed; retry action' in v_definition)=0 then
    raise exception 'captain action accepted a changed pair identity';
  end if;
  if exists(
    select 1
    from pace_v2.captain_leg_operations operation
    join pace_v2.confirmed_allocations allocation
      on allocation.id=operation.confirmed_allocation_id
    join pace_v2.departures outbound on outbound.id=allocation.departure_id
    left join pace_v2.journey_pairs pair on pair.id=outbound.journey_pair_id
    where operation.departure_id<>outbound.id
      and operation.departure_id is distinct from pair.return_departure_id
  ) then raise exception 'captain evidence used an unvalidated duty identity'; end if;
end $$;

-- A malformed operational timezone is isolated from the projection and
-- rejected before an action evaluates AT TIME ZONE.
update pace_v2.countries country set timezone='Invalid/Captain_Contract'
from captain_today_fixture f
join pace_v2.departures d on d.id=f.outbound_id
join pace_v2.routes r on r.id=d.route_id
where country.id=r.country_id;

do $$ declare v_count integer; begin
  select count(*) into v_count from public.v2_captain_today_duties duty
  join captain_today_fixture f on f.allocation_id=duty.duty_id;
  if v_count<>0 then raise exception 'invalid country timezone broke the captain Today projection'; end if;
end $$;

set local role authenticated;
do $$ declare v_error text; begin
  begin perform public.v2_captain_start_leg((select outbound_id from captain_today_fixture));
  exception when others then v_error:=sqlerrm; end;
  if v_error is distinct from 'captain duty timezone is invalid' then
    raise exception 'invalid country timezone action did not return the domain error: %',v_error;
  end if;
end $$;
reset role;

update pace_v2.countries country set timezone='UTC'
from captain_today_fixture f
join pace_v2.departures d on d.id=f.outbound_id
join pace_v2.routes r on r.id=d.route_id
where country.id=r.country_id;

-- Give the untouched source allocation its own fresh party and eligible captain
-- only after the paired lifecycle has completed, so its compatibility evidence
-- cannot share paired notifications, conversations, or completion state.
do $captain_one_way_self_seed$
declare
  fixture captain_today_fixture%rowtype;
  primary_allocation pace_v2.confirmed_allocations%rowtype;
  primary_consideration pace_v2.vehicle_considerations%rowtype;
  service pace_v2.services%rowtype;
  route pace_v2.routes%rowtype;
  v_order_id uuid;
  v_booking_id uuid:=gen_random_uuid();
  v_assignment_id uuid;
  v_captain_id uuid;
  v_allocation_id uuid;
  v_operator_id uuid;
  v_vehicle_type_id uuid;
  v_departure_id uuid:=gen_random_uuid();
  v_consideration_id uuid;
  v_first_operating_date date;
  v_operating_date date;
  v_departure_ts timestamptz;
  v_pair_id uuid;
  v_return_id uuid;
begin
  select * into fixture from captain_today_fixture limit 1;
  select * into primary_allocation from pace_v2.confirmed_allocations
  where id=fixture.allocation_id;
  select * into primary_consideration from pace_v2.vehicle_considerations
  where id=primary_allocation.consideration_id;
  select * into service from pace_v2.services
  where id=(select departure.service_id from pace_v2.departures departure
            where departure.id=fixture.outbound_id);
  select * into route from pace_v2.routes where id=service.route_id;
  select vehicle.vehicle_type_id into v_vehicle_type_id
  from pace_v2.vehicles vehicle where vehicle.id=primary_allocation.vehicle_id;
  v_operator_id:=primary_allocation.operator_id;

  v_first_operating_date:=pace_v2.next_service_operating_date(
    service.id,service.departure_time
  );
  select v_first_operating_date+candidate.day_offset
    into v_operating_date
  from generate_series(0,4095) candidate(day_offset)
  where v_first_operating_date is not null
    and (service.valid_to is null
      or v_first_operating_date+candidate.day_offset<=service.valid_to)
    and extract(dow from v_first_operating_date+candidate.day_offset)::smallint
      =any(service.days_of_week)
    and (
      coalesce(service.recurrence_type,'weekly')<>'weekly'
      or mod(
        ((v_first_operating_date+candidate.day_offset)
          -coalesce(service.recurrence_anchor_date,service.valid_from,
            (now() at time zone service.timezone)::date))/7,
        greatest(coalesce(service.recurrence_interval_weeks,1),1)
      )=0
    )
    and (((v_first_operating_date+candidate.day_offset)::timestamp
      +service.departure_time) at time zone service.timezone)>now()
    and not exists(
      select 1 from pace_v2.departures existing
      where existing.service_id=service.id
        and existing.local_departure_date=v_first_operating_date+candidate.day_offset
        and existing.is_commercial
    )
  order by candidate.day_offset
  limit 1;
  if v_operating_date is null then
    raise exception 'fixture: primary service available next one-way operating date required';
  end if;
  v_departure_ts:=(v_operating_date::timestamp+service.departure_time)
    at time zone service.timezone;
  insert into pace_v2.departures(
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
    trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial
  ) values(
    v_departure_id,service.id,route.id,v_departure_ts,
    v_departure_ts+make_interval(mins=>coalesce(route.approx_duration_mins,60)),
    service.timezone,v_operating_date,
    v_departure_ts-make_interval(hours=>coalesce(route.t72_hours,72)),
    v_departure_ts-make_interval(hours=>coalesce(route.t24_hours,24)),
    'confirmed',true
  );
  select departure.journey_pair_id into v_pair_id from pace_v2.departures departure
  where departure.id=v_departure_id;
  if v_pair_id is not null then
    select pair.return_departure_id into v_return_id from pace_v2.journey_pairs pair
    where pair.id=v_pair_id;
    perform set_config('pace_v2.journey_pair_mutation_authorized','on',true);
    update pace_v2.departures set journey_pair_id=null,leg_number=null
    where id in(v_departure_id,v_return_id);
    delete from pace_v2.journey_pairs where id=v_pair_id;
    delete from pace_v2.departures where id=v_return_id;
    perform set_config('pace_v2.journey_pair_mutation_authorized','off',true);
  end if;

  insert into pace_v2.vehicle_considerations(
    departure_id,vehicle_route_offer_id,vehicle_id,operator_id,status,
    normal_min_seats,max_seats,min_revenue_cents,min_value_threshold_ratio,
    normal_base_seat_price_cents,assigned_seats,assigned_revenue_cents,
    minimum_achieved_at,discount_activated_at,opened_at,under_consideration_at,
    withdrawal_deadline_ts,withdrawn_at,withdrawal_reason,t72_discarded_at,
    quality_score_snapshot,effective_commission_bps,effective_commission_source,
    engine_version,post_min_discount_enabled,post_min_discount_bps,
    commercial_snapshot_locked_at,commercial_snapshot_source,
    below_minimum_operation_mode
  ) values(
    v_departure_id,primary_consideration.vehicle_route_offer_id,
    primary_allocation.vehicle_id,v_operator_id,'eligible',
    primary_consideration.normal_min_seats,primary_consideration.max_seats,
    primary_consideration.min_revenue_cents,primary_consideration.min_value_threshold_ratio,
    primary_consideration.normal_base_seat_price_cents,0,0,
    null,null,now(),now(),primary_consideration.withdrawal_deadline_ts,
    null,null,null,primary_consideration.quality_score_snapshot,
    primary_consideration.effective_commission_bps,
    primary_consideration.effective_commission_source,
    primary_consideration.engine_version,primary_consideration.post_min_discount_enabled,
    primary_consideration.post_min_discount_bps,null,
    primary_consideration.commercial_snapshot_source,
    primary_consideration.below_minimum_operation_mode
  ) returning id into v_consideration_id;

  insert into pace_v2.confirmed_allocations(
    departure_id,vehicle_id,operator_id,consideration_id,confirmed_at,confirmed_by,
    operator_journey_value_cents,effective_commission_bps,pace_shuttles_commission_cents,
    operator_net_before_adjustments_cents,status,completed_at,created_at
  ) values(
    v_departure_id,primary_allocation.vehicle_id,v_operator_id,v_consideration_id,
    now(),primary_allocation.confirmed_by,primary_allocation.operator_journey_value_cents,
    primary_allocation.effective_commission_bps,
    primary_allocation.pace_shuttles_commission_cents,
    primary_allocation.operator_net_before_adjustments_cents,'confirmed',null,now()
  ) returning id into v_allocation_id;

  select captain.id into v_captain_id from pace_v2.captains captain
  where captain.auth_user_id=fixture.other_captain_user_id;
  insert into pace_v2.captain_vehicle_types(captain_id,vehicle_type_id,active)
  values(v_captain_id,v_vehicle_type_id,true)
  on conflict(captain_id,vehicle_type_id) do update set active=true;
  insert into pace_v2.captain_assignments(
    confirmed_allocation_id,captain_id,assignment_source,active
  ) values(v_allocation_id,v_captain_id,'auto',true)
  returning id into v_assignment_id;

  insert into pace_v2.orders(
    customer_user_id,customer_email,customer_name,currency,subtotal_cents,
    tax_rate_bps,customer_fee_rate_bps,taxes_cents,fees_cents,total_cents,
    payment_status,paid_at,fulfillment_status
  ) values(
    fixture.customer_user_id,
    'customer-fixture+'||replace(fixture.customer_user_id::text,'-','')||'@example.invalid',
    'Rollback One Way','USD',1000,0,0,0,0,1000,'paid',now(),'booked'
  ) returning id into v_order_id;
  insert into pace_v2.bookings(
    id,order_id,departure_id,route_id,customer_name,seats,status,currency,
    unit_price_cents,total_price_cents,paid_at
  ) values(
    v_booking_id,v_order_id,v_departure_id,route.id,
    'Rollback One Way',1,'confirmed','USD',1000,1000,now()
  );
  insert into pace_v2.booking_allocations(
    booking_id,vehicle_consideration_id,departure_id,seats,unit_price_cents
  ) values(v_booking_id,v_consideration_id,v_departure_id,1,1000);
  update captain_today_fixture set
    source_allocation_2_id=v_allocation_id,
    allocation_2_original_departure_id=v_departure_id;
end
$captain_one_way_self_seed$;

create temporary table captain_one_way_compat_fixture(
  allocation_id uuid not null,
  assignment_id uuid not null,
  departure_id uuid not null,
  captain_user_id uuid not null,
  booking_id uuid not null,
  legacy_started_at timestamptz,
  legacy_ended_at timestamptz,
  completed_voyage_count integer not null default 0,
  feedback_count integer not null default 0
) on commit drop;
grant select,update on captain_one_way_compat_fixture to authenticated;

insert into captain_one_way_compat_fixture(
  allocation_id,assignment_id,departure_id,captain_user_id,booking_id
)
select ca.id,assignment.id,departure.id,captain.auth_user_id,booking.id
from pace_v2.confirmed_allocations ca
join pace_v2.departures departure on departure.id=ca.departure_id
  and departure.journey_pair_id is null
  and departure.actual_departure_ts is null and departure.actual_arrival_ts is null
join pace_v2.vehicles vehicle on vehicle.id=ca.vehicle_id and vehicle.active
join pace_v2.captain_assignments assignment
  on assignment.confirmed_allocation_id=ca.id and assignment.active
join pace_v2.captains captain on captain.id=assignment.captain_id and captain.active
  and captain.operator_id=ca.operator_id and captain.auth_user_id is not null
join pace_v2.captain_vehicle_types eligibility on eligibility.captain_id=captain.id
  and eligibility.vehicle_type_id=vehicle.vehicle_type_id and eligibility.active
join pace_v2.booking_allocations booking_allocation
  on booking_allocation.vehicle_consideration_id=ca.consideration_id
join pace_v2.bookings booking on booking.id=booking_allocation.booking_id
  and pace_v2.is_active_paid_journey_booking(booking.id,null)
where ca.status='confirmed'
  and ca.id not in(select allocation_id from captain_today_fixture union all select allocation_2_id from captain_today_fixture)
  and booking.id<>(select booking_2_id from captain_today_fixture)
  and (select count(*) from pace_v2.captain_assignments other
       where other.confirmed_allocation_id=ca.id and other.active)=1
order by ca.id limit 1;

do $$ begin
  if not exists(select 1 from captain_one_way_compat_fixture) then
    raise exception 'fixture: clean one-way captain allocation required';
  end if;
end $$;

do $$
declare
  v_total_count integer;
  v_confirmed_count integer;
  v_statuses text;
begin
  select count(*),count(*) filter(where allocation.status='confirmed'),
         string_agg(allocation.status,',' order by allocation.status)
    into v_total_count,v_confirmed_count,v_statuses
  from captain_one_way_compat_fixture fixture
  join pace_v2.confirmed_allocations allocation
    on allocation.departure_id=fixture.departure_id;
  if v_total_count<>1 or v_confirmed_count<>1 then
    raise exception 'one-way compatibility fixture expected exactly one confirmed allocation: total %, confirmed %, statuses %',
      v_total_count,v_confirmed_count,coalesce(v_statuses,'none');
  end if;
end $$;

update pace_v2.countries country set timezone='UTC'
from captain_one_way_compat_fixture f
join pace_v2.departures departure on departure.id=f.departure_id
join pace_v2.routes route on route.id=departure.route_id
where country.id=route.country_id;
update pace_v2.departures departure
set scheduled_departure_ts=date_trunc('day',now())+interval '9 hours',
    scheduled_arrival_ts=date_trunc('day',now())+interval '11 hours',
    local_departure_date=(now() at time zone 'UTC')::date
from captain_one_way_compat_fixture f where departure.id=f.departure_id;

do $$
declare v_status text;
begin
  select departure.status into v_status
  from captain_one_way_compat_fixture fixture
  join pace_v2.departures departure on departure.id=fixture.departure_id;
  if v_status is distinct from 'confirmed' then
    raise exception 'one-way compatibility fixture departure was not confirmed before completion: %',
      coalesce(v_status,'missing');
  end if;
end $$;

select set_config('request.jwt.claim.sub',(select captain_user_id::text from captain_one_way_compat_fixture),true);
set local role authenticated;
do $$ declare v_actual timestamptz; v_retry timestamptz; begin
  perform public.v2_captain_start_journey(
    p_captain_assignment_id=>(select assignment_id from captain_one_way_compat_fixture)
  );
  select duty.leg_1_started_at
    into v_actual
  from public.v2_captain_today_duties duty
  join captain_one_way_compat_fixture f on duty.duty_id=f.allocation_id;
  update captain_one_way_compat_fixture set legacy_started_at=v_actual;
  if not exists(
    select 1 from public.v2_captain_today_duties duty
    join captain_one_way_compat_fixture f on duty.duty_id=f.allocation_id
    where duty.leg_1_started_at=f.legacy_started_at and duty.duty_state='leg_1_in_progress'
  ) then raise exception 'legacy one-way in-progress timestamp was not adopted'; end if;
  v_retry:=public.v2_captain_start_leg((select departure_id from captain_one_way_compat_fixture));
  if v_retry is distinct from v_actual then raise exception 'legacy one-way start retry changed its timestamp'; end if;

  begin
    perform public.v2_captain_complete_journey(
      p_captain_assignment_id=>(select assignment_id from captain_one_way_compat_fixture),
      p_completed_normally=>true,p_captain_notes=>'legacy one-way complete',
      p_incident_flag=>false,p_incident_summary=>''
    );
  exception when others then
    raise exception 'ordinary one-way legacy completion was rejected: %',sqlerrm;
  end;
  if exists(
    select 1 from public.v2_captain_today_duties duty
    join captain_one_way_compat_fixture f on duty.duty_id=f.allocation_id
  ) then raise exception 'completed one-way duty remained in Today'; end if;
  v_actual:=public.v2_captain_end_leg(
    (select departure_id from captain_one_way_compat_fixture),'normal','legacy one-way complete',''
  );
  v_retry:=public.v2_captain_end_leg(
    (select departure_id from captain_one_way_compat_fixture),'normal','legacy one-way complete',''
  );
  if v_retry is distinct from v_actual then raise exception 'legacy one-way completion retry changed its timestamp'; end if;
  update captain_one_way_compat_fixture set legacy_ended_at=v_actual;
end $$;
reset role;

do $$ begin
  if not exists(
    select 1 from captain_one_way_compat_fixture f
    join pace_v2.departures departure on departure.id=f.departure_id
    where departure.status='completed'
  ) then raise exception 'legacy one-way canonical completion did not set departure completed status'; end if;
  if not exists(
    select 1 from captain_one_way_compat_fixture f
    join pace_v2.departures departure on departure.id=f.departure_id
    where departure.completed_at is not null
  ) then raise exception 'legacy one-way canonical completion did not set departure completed timestamp'; end if;
  if not exists(
    select 1 from captain_one_way_compat_fixture f
    join pace_v2.departures departure on departure.id=f.departure_id
    where departure.actual_arrival_ts=f.legacy_ended_at
  ) then raise exception 'legacy one-way canonical completion did not persist departure arrival'; end if;
  if not exists(
    select 1 from captain_one_way_compat_fixture f
    join pace_v2.confirmed_allocations allocation on allocation.id=f.allocation_id
    where allocation.status='completed'
  ) then raise exception 'legacy one-way canonical completion did not set allocation completed'; end if;
  if not exists(
    select 1 from captain_one_way_compat_fixture f
    join pace_v2.voyage_logs voyage on voyage.confirmed_allocation_id=f.allocation_id
    where voyage.actual_arrival_ts=f.legacy_ended_at
  ) then raise exception 'legacy one-way canonical completion did not persist voyage arrival'; end if;
  if not exists(
    select 1 from captain_one_way_compat_fixture f
    join pace_v2.captain_leg_operations operation
      on operation.confirmed_allocation_id=f.allocation_id
     and operation.departure_id=f.departure_id
    where operation.ended_at=f.legacy_ended_at
      and operation.completion_state='normal'
      and operation.notes='legacy one-way complete'
  ) then raise exception 'legacy one-way compatibility did not persist completed operation evidence'; end if;
end $$;

update captain_one_way_compat_fixture f set
  completed_voyage_count=(select count(*) from pace_v2.voyage_logs voyage
    where voyage.confirmed_allocation_id=f.allocation_id and voyage.actual_arrival_ts is not null),
  feedback_count=(select count(*) from pace_v2.notifications notification
    where notification.booking_id=f.booking_id and notification.template_code='post_journey_feedback');

do $$ begin
  if exists(
    select 1 from captain_one_way_compat_fixture f
    where (select count(*) from pace_v2.voyage_logs voyage
           where voyage.confirmed_allocation_id=f.allocation_id and voyage.actual_arrival_ts is not null)
            <> f.completed_voyage_count
       or (select count(*) from pace_v2.notifications notification
           where notification.booking_id=f.booking_id and notification.template_code='post_journey_feedback')
            <> f.feedback_count
  ) then raise exception 'new one-way compatibility retry duplicated legacy integration'; end if;
end $$;

select set_config('request.jwt.claim.sub',(
  select p.user_id::text
  from pace_v2.profiles p
  where p.platform_role is distinct from 'site_admin'
  order by p.user_id
  limit 1
),true);
set local role authenticated;

do $non_admin_pairing_contract$
declare
  v_rejected boolean:=false;
begin
  if auth.uid() is null then
    raise exception 'fixture: a non-admin profile is required';
  end if;
  begin
    insert into pace_v2.journey_pairs(outbound_departure_id,return_departure_id)
    values(
      current_setting('test.captain_one_way_id')::uuid,
      current_setting('test.captain_return_id')::uuid
    );
  exception when insufficient_privilege then
    v_rejected:=true;
  end;
  if not v_rejected then
    raise exception 'non-admin journey pair creation was accepted';
  end if;
end
$non_admin_pairing_contract$;

reset role;

rollback;
