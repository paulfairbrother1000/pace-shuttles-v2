begin;

do $$
declare
  source_departure pace_v2.departures%rowtype;
  source_booking record;
  cloned_consideration_id uuid;
  cloned_vehicle_id uuid;
  impossible_booking_id uuid;
  impossible_consideration_id uuid;
  impossible_vehicle_id uuid;
  test_departure_id uuid := gen_random_uuid();
  booking_id uuid;
  result record;
  t24_result jsonb;
  survivor_count integer;
  offer_count integer;
begin
  select * into source_departure
  from pace_v2.departures
  where id='e65269ee-0ced-400a-b99d-5627a2b83a0a';

  if not found then
    raise exception 'six-party source template is unavailable';
  end if;

  drop table if exists pg_temp.pace_t72_fixture_considerations;
  create temporary table pace_t72_fixture_considerations(
    source_id uuid primary key,
    clone_id uuid not null,
    vehicle_id uuid not null
  ) on commit drop;

  insert into pg_temp.pace_t72_fixture_considerations(source_id,clone_id,vehicle_id)
  select vc.id,gen_random_uuid(),vc.vehicle_id
  from pace_v2.vehicle_considerations vc
  where vc.departure_id=source_departure.id;

  if (select count(*) from pg_temp.pace_t72_fixture_considerations)<>5 then
    raise exception 'six-party source template no longer has five vehicle considerations';
  end if;

  insert into pace_v2.departures(
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
    trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial
  ) values (
    test_departure_id,source_departure.service_id,source_departure.route_id,
    source_departure.scheduled_departure_ts+interval '200 years',
    source_departure.scheduled_arrival_ts+interval '200 years',
    source_departure.trip_timezone,source_departure.local_departure_date+73048,
    now()+interval '1 hour',now()+interval '25 hours','scheduled',true
  );

  insert into pace_v2.vehicle_considerations(
    id,departure_id,vehicle_route_offer_id,vehicle_id,operator_id,status,
    normal_min_seats,max_seats,min_revenue_cents,min_value_threshold_ratio,
    normal_base_seat_price_cents,assigned_seats,assigned_revenue_cents,
    quality_score_snapshot,effective_commission_bps,effective_commission_source,
    engine_version,post_min_discount_enabled,post_min_discount_bps,
    commercial_snapshot_source,below_minimum_operation_mode
  )
  select
    map.clone_id,test_departure_id,vc.vehicle_route_offer_id,vc.vehicle_id,
    vc.operator_id,'eligible',vc.normal_min_seats,vc.max_seats,
    vc.min_revenue_cents,vc.min_value_threshold_ratio,
    vc.normal_base_seat_price_cents,0,0,vc.quality_score_snapshot,
    vc.effective_commission_bps,vc.effective_commission_source,
    't72-controlled-fixture',vc.post_min_discount_enabled,
    vc.post_min_discount_bps,vc.commercial_snapshot_source,
    vc.below_minimum_operation_mode
  from pace_v2.vehicle_considerations vc
  join pg_temp.pace_t72_fixture_considerations map on map.source_id=vc.id;

  for source_booking in
    select b.customer_name,b.seats,b.currency,b.unit_price_cents,
           b.total_price_cents,b.commercial_snapshot,
           ba.vehicle_consideration_id as source_consideration_id
    from pace_v2.bookings b
    join lateral (
      select active_ba.vehicle_consideration_id
      from pace_v2.booking_allocations active_ba
      where active_ba.booking_id=b.id
      order by active_ba.allocated_at desc,active_ba.id
      limit 1
    ) ba on true
    where b.departure_id=source_departure.id
    order by b.id
  loop
    select map.clone_id,map.vehicle_id
    into cloned_consideration_id,cloned_vehicle_id
    from pg_temp.pace_t72_fixture_considerations map
    where map.source_id=source_booking.source_consideration_id;

    booking_id:=gen_random_uuid();
    insert into pace_v2.bookings(
      id,departure_id,route_id,customer_name,seats,status,currency,
      unit_price_cents,total_price_cents,preliminary_vehicle_id,
      commercial_snapshot
    ) values (
      booking_id,test_departure_id,source_departure.route_id,
      coalesce(source_booking.customer_name,'T-72 fixture'),
      source_booking.seats,'booked',source_booking.currency,
      source_booking.unit_price_cents,source_booking.total_price_cents,
      cloned_vehicle_id,
      jsonb_build_object('quote_snapshot',jsonb_build_object(
        'discount_applied',
          coalesce(source_booking.commercial_snapshot#>>'{quote_snapshot,discount_applied}','false')::boolean,
        'vehicle_consideration_id',cloned_consideration_id
      ))
    );

    insert into pace_v2.booking_allocations(
      booking_id,departure_id,vehicle_consideration_id,vehicle_id,status,
      seats,unit_price_cents,allocation_reason
    ) values (
      booking_id,test_departure_id,cloned_consideration_id,cloned_vehicle_id,
      'preliminary',source_booking.seats,source_booking.unit_price_cents,
      'controlled T-72 fixture'
    );
  end loop;

  if (select count(*) from pace_v2.bookings where departure_id=test_departure_id)<>6
     or (select sum(seats) from pace_v2.bookings where departure_id=test_departure_id)<>21 then
    raise exception 'controlled T-72 fixture must contain six parties and 21 seats';
  end if;

  perform pace_v2.refresh_consideration_totals(test_departure_id);

  select count(*) into offer_count
  from pace_v2.get_live_party_offer_candidates(test_departure_id,1);

  if offer_count=0 then
    raise exception 'controlled pre-T-72 fixture produced no candidate offers';
  end if;

  if exists (
    select 1
    from pace_v2.get_live_party_offer_candidates(test_departure_id, 1) candidate
    where candidate.discount_applied
  ) then
    raise exception 'discounts were offered before T-72';
  end if;

  update pace_v2.departures
  set t72_ts=now()-interval '1 minute',
      t24_ts=now()+interval '23 hours'
  where id=test_departure_id;

  select * into result
  from pace_v2.evaluate_t72_booked_parties(
    test_departure_id,
    't72-t24-behavior-red-green'
  );

  if result.outcome <> 'viable' or result.viable_vehicle_count <> 3 then
    raise exception 'expected three viable vehicles after T-72 rebalance, got % / %',
      result.outcome, result.viable_vehicle_count;
  end if;

  if exists (
    select 1
    from pace_v2.bookings b
    where b.departure_id=test_departure_id
      and b.status in ('booked','at_risk','confirmed')
      and (
        select count(*)
        from pace_v2.booking_allocations ba
        where ba.booking_id=b.id
          and ba.status in ('preliminary','confirmed')
          and ba.seats=b.seats
      ) <> 1
  ) then
    raise exception 'T-72 rebalance split or orphaned a booking party';
  end if;

  if exists (
    select 1
    from pace_v2.bookings b
    join pace_v2.booking_allocations ba
      on ba.booking_id=b.id
     and ba.status in ('preliminary','confirmed')
    where b.departure_id=test_departure_id
      and b.commercial_snapshot#>>'{quote_snapshot,discount_applied}'='true'
      and ba.vehicle_consideration_id::text <>
          b.commercial_snapshot#>>'{quote_snapshot,vehicle_consideration_id}'
  ) then
    raise exception 'a discounted booking moved away from the vehicle that offered it';
  end if;

  select count(*) into survivor_count
  from pace_v2.vehicle_considerations vc
  where vc.departure_id=test_departure_id
    and vc.status='under_consideration'
    and vc.assigned_seats >= vc.normal_min_seats;

  if survivor_count <> 3 then
    raise exception 'every T-72 survivor must meet its minimum seats';
  end if;

  select * into result
  from pace_v2.evaluate_t72_booked_parties(
    test_departure_id,
    't72-t24-repeat-behavior'
  );

  if result.outcome<>'viable' or result.viable_vehicle_count<>3 then
    raise exception 'T-72 rerun changed the viable allocation result';
  end if;

  select b.id into impossible_booking_id
  from pace_v2.bookings b
  where b.departure_id=test_departure_id
  order by b.seats,b.id
  limit 1;

  select vc.id,vc.vehicle_id
  into impossible_consideration_id,impossible_vehicle_id
  from pace_v2.vehicle_considerations vc
  where vc.departure_id=test_departure_id
    and vc.status='discarded_t72'
    and vc.max_seats>=(select seats from pace_v2.bookings where id=impossible_booking_id)
  order by vc.id
  limit 1;

  update pace_v2.booking_allocations ba
  set vehicle_consideration_id=impossible_consideration_id,
      vehicle_id=impossible_vehicle_id
  where ba.booking_id=impossible_booking_id
    and ba.status in ('preliminary','confirmed');

  update pace_v2.bookings
  set preliminary_vehicle_id=impossible_vehicle_id,
      commercial_snapshot=jsonb_build_object('quote_snapshot',jsonb_build_object(
        'discount_applied',true,
        'vehicle_consideration_id',impossible_consideration_id
      ))
  where id=impossible_booking_id;

  perform pace_v2.refresh_consideration_totals(test_departure_id);

  select * into result
  from pace_v2.evaluate_t72_booked_parties(
    test_departure_id,
    't72-no-feasible-plan-fixture'
  );

  if result.outcome not in ('at_risk_rescue','at_risk_no_rescue')
     or (select status from pace_v2.departures where id=test_departure_id)<>'at_risk'
     or not exists (
       select 1 from pace_v2.allocation_decisions ad
       where ad.departure_id=test_departure_id
         and ad.decision_reason_code='T72_NO_FEASIBLE_WHOLE_PARTY_PLAN'
     ) then
    raise exception 'an unsatisfiable T-72 plan was not retained as an auditable at-risk outcome';
  end if;

  if result.outcome='at_risk_rescue' and coalesce(result.rescue_gap_cents,0)<=0 then
    raise exception 'T-72 created a rescue without a positive revenue gap';
  end if;

  select pace_v2.process_departure_t24(
    test_departure_id,
    't24-no-feasible-plan-fixture',
    true
  ) into t24_result;

  if t24_result->>'outcome'<>'at_risk_manual_review'
     or not exists (
       select 1 from pace_v2.scheduled_job_runs sjr
       where sjr.departure_id=test_departure_id
         and sjr.phase='t24'
         and sjr.status='completed'
     )
     or not exists (
       select 1 from pace_v2.allocation_decisions ad
       where ad.departure_id=test_departure_id
         and ad.decision_reason_code='T24_INCOMPLETE_BOOKING_COVERAGE'
     ) then
    raise exception 'unresolved T-72 allocation did not reach an audited T-24 manual-review outcome';
  end if;
end
$$;

do $$
begin
  if has_function_privilege('anon','pace_v2.evaluate_t72_booked_parties(uuid,text)','EXECUTE')
     or has_function_privilege('authenticated','pace_v2.evaluate_t72_booked_parties(uuid,text)','EXECUTE')
     or has_function_privilege('anon','pace_v2.process_departure_t24(uuid,text,boolean)','EXECUTE')
     or has_function_privilege('authenticated','pace_v2.process_departure_t24(uuid,text,boolean)','EXECUTE')
     or has_function_privilege('anon','pace_v2.process_departure_t72(uuid,text,boolean)','EXECUTE')
     or has_function_privilege('authenticated','pace_v2.process_departure_t72(uuid,text,boolean)','EXECUTE')
     or has_function_privilege('anon','pace_v2.confirm_departure_t24(uuid,boolean,text)','EXECUTE')
     or has_function_privilege('authenticated','pace_v2.confirm_departure_t24(uuid,boolean,text)','EXECUTE')
     or has_function_privilege('anon','pace_v2.get_live_party_offer(uuid,integer)','EXECUTE')
     or has_function_privilege('authenticated','pace_v2.get_live_party_offer(uuid,integer)','EXECUTE')
     or has_function_privilege('anon','pace_v2.get_live_party_offer_candidates(uuid,integer)','EXECUTE')
     or has_function_privilege('authenticated','pace_v2.get_live_party_offer_candidates(uuid,integer)','EXECUTE') then
    raise exception 'internal lifecycle function remains directly executable';
  end if;
end
$$;

rollback;

begin;

do $$
declare
  source_departure pace_v2.departures%rowtype;
  source_consideration pace_v2.vehicle_considerations%rowtype;
  second_consideration pace_v2.vehicle_considerations%rowtype;
  test_departure_id uuid := gen_random_uuid();
  first_consideration_id uuid := gen_random_uuid();
  second_consideration_id uuid := gen_random_uuid();
  booking_id uuid;
  i integer;
  active_vehicle_count integer;
  distinct_booking_vehicle_count integer;
  moved_count integer;
  t24_result jsonb;
begin
  select * into source_departure
  from pace_v2.departures
  where id='e65269ee-0ced-400a-b99d-5627a2b83a0a';

  select vc.* into source_consideration
  from pace_v2.vehicle_considerations vc
  where vc.departure_id=source_departure.id
    and vc.operator_id=(
      select operator_id
      from pace_v2.vehicle_considerations
      where departure_id=source_departure.id
      group by operator_id
      having count(*) >= 2
      order by count(*) desc
      limit 1
    )
  order by vc.max_seats desc,vc.id
  limit 1;

  select vc.* into second_consideration
  from pace_v2.vehicle_considerations vc
  where vc.departure_id=source_departure.id
    and vc.operator_id=source_consideration.operator_id
    and vc.id<>source_consideration.id
  order by vc.max_seats desc,vc.id
  limit 1;

  insert into pace_v2.departures(
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
    trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial
  ) values (
    test_departure_id,source_departure.service_id,source_departure.route_id,
    source_departure.scheduled_departure_ts+interval '100 years',
    source_departure.scheduled_arrival_ts+interval '100 years',
    source_departure.trip_timezone,source_departure.local_departure_date+36524,
    now()-interval '48 hours',now()-interval '1 minute',
    'under_consideration',true
  );

  insert into pace_v2.vehicle_considerations(
    id,departure_id,vehicle_route_offer_id,vehicle_id,operator_id,status,
    normal_min_seats,max_seats,min_revenue_cents,min_value_threshold_ratio,
    normal_base_seat_price_cents,assigned_seats,assigned_revenue_cents,
    quality_score_snapshot,effective_commission_bps,effective_commission_source,
    engine_version,post_min_discount_enabled,post_min_discount_bps,
    commercial_snapshot_source,below_minimum_operation_mode
  )
  select
    first_consideration_id,test_departure_id,vehicle_route_offer_id,vehicle_id,
    operator_id,'under_consideration',4,max_seats,20000,null,5000,0,0,
    quality_score_snapshot,effective_commission_bps,effective_commission_source,
    't24-consolidation-fixture',post_min_discount_enabled,post_min_discount_bps,
    commercial_snapshot_source,'never'
  from pace_v2.vehicle_considerations where id=source_consideration.id;

  insert into pace_v2.vehicle_considerations(
    id,departure_id,vehicle_route_offer_id,vehicle_id,operator_id,status,
    normal_min_seats,max_seats,min_revenue_cents,min_value_threshold_ratio,
    normal_base_seat_price_cents,assigned_seats,assigned_revenue_cents,
    quality_score_snapshot,effective_commission_bps,effective_commission_source,
    engine_version,post_min_discount_enabled,post_min_discount_bps,
    commercial_snapshot_source,below_minimum_operation_mode
  )
  select
    second_consideration_id,test_departure_id,vehicle_route_offer_id,vehicle_id,
    operator_id,'under_consideration',4,max_seats,20000,null,5000,0,0,
    quality_score_snapshot,effective_commission_bps,effective_commission_source,
    't24-consolidation-fixture',post_min_discount_enabled,post_min_discount_bps,
    commercial_snapshot_source,'never'
  from pace_v2.vehicle_considerations where id=second_consideration.id;

  for i in 1..4 loop
    booking_id := gen_random_uuid();
    insert into pace_v2.bookings(
      id,departure_id,route_id,customer_name,seats,status,currency,
      unit_price_cents,total_price_cents,preliminary_vehicle_id,commercial_snapshot
    ) values (
      booking_id,test_departure_id,source_departure.route_id,'Fleet fixture '||i,
      2,'booked','USD',5000,10000,
      case when i<=2 then source_consideration.vehicle_id else second_consideration.vehicle_id end,
      jsonb_build_object('quote_snapshot',jsonb_build_object(
        'discount_applied',false,
        'vehicle_consideration_id',
          case when i<=2 then first_consideration_id else second_consideration_id end
      ))
    );

    insert into pace_v2.booking_allocations(
      booking_id,departure_id,vehicle_consideration_id,vehicle_id,status,
      seats,unit_price_cents,allocation_reason
    ) values (
      booking_id,test_departure_id,
      case when i<=2 then first_consideration_id else second_consideration_id end,
      case when i<=2 then source_consideration.vehicle_id else second_consideration.vehicle_id end,
      'confirmed',2,5000,'T-24 consolidation fixture'
    );
  end loop;

  perform pace_v2.refresh_consideration_totals(test_departure_id);

  update pace_v2.bookings b
  set commercial_snapshot=jsonb_set(
    b.commercial_snapshot,
    '{quote_snapshot,discount_applied}',
    'true'::jsonb
  )
  where b.id in (
    select distinct on (ba.vehicle_consideration_id) ba.booking_id
    from pace_v2.booking_allocations ba
    where ba.departure_id=test_departure_id
      and ba.status in ('preliminary','confirmed')
    order by ba.vehicle_consideration_id,ba.booking_id
  );

  select pace_v2.consolidate_operator_fleet_t24(
    test_departure_id,
    source_consideration.operator_id,
    't24-discount-lock-fixture'::text
  ) into moved_count;

  if moved_count<>0 then
    raise exception 'T-24 moved a party away from its discount vehicle';
  end if;

  update pace_v2.vehicle_considerations
  set status='discarded_t72'
  where id=second_consideration_id;

  select pace_v2.process_departure_t24(
    test_departure_id,
    't24-incomplete-coverage-fixture',
    true
  ) into t24_result;

  if t24_result->>'outcome'<>'at_risk_manual_review'
     or (select status from pace_v2.departures where id=test_departure_id)<>'at_risk' then
    raise exception 'T-24 incomplete coverage did not produce a manual-review outcome';
  end if;

  update pace_v2.departures
  set status='under_consideration',at_risk_reason=null
  where id=test_departure_id;

  update pace_v2.bookings
  set status='booked'
  where departure_id=test_departure_id and status='at_risk';

  update pace_v2.vehicle_considerations
  set status='under_consideration'
  where id=second_consideration_id;

  update pace_v2.bookings b
  set commercial_snapshot=jsonb_set(
    b.commercial_snapshot,
    '{quote_snapshot,discount_applied}',
    'false'::jsonb
  )
  where b.departure_id=test_departure_id;

  select pace_v2.consolidate_operator_fleet_t24(
    test_departure_id,
    source_consideration.operator_id,
    't24-consolidation-fixture'::text
  ) into moved_count;

  if moved_count <> 2 then
    raise exception 'expected two whole parties to move during T-24 consolidation, got %', moved_count;
  end if;

  select count(*) into active_vehicle_count
  from pace_v2.vehicle_considerations
  where departure_id=test_departure_id and status='under_consideration';

  select count(distinct vehicle_id) into distinct_booking_vehicle_count
  from pace_v2.booking_allocations
  where departure_id=test_departure_id and status in ('preliminary','confirmed');

  if active_vehicle_count<>1 or distinct_booking_vehicle_count<>1 then
    raise exception 'T-24 did not consolidate the operator onto one vehicle';
  end if;

  if exists (
    select 1
    from pace_v2.bookings b
    join pace_v2.booking_allocations ba on ba.booking_id=b.id
    where b.departure_id=test_departure_id
      and ba.status in ('preliminary','confirmed')
      and (
        ba.seats<>b.seats
        or ba.unit_price_cents<>b.unit_price_cents
        or b.total_price_cents<>b.seats*b.unit_price_cents
      )
  ) then
    raise exception 'T-24 consolidation changed party size or customer price';
  end if;

  if not exists (
    select 1 from pace_v2.vehicle_considerations
    where departure_id=test_departure_id
      and status='replaced'
      and t24_resolution_reason='Not required — operator fleet consolidated at T-24.'
  ) then
    raise exception 'T-24 consolidation reason was not recorded';
  end if;
end
$$;

rollback;
