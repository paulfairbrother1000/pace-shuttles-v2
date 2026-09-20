begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(26);

do $fixture$
declare
  source_departure pace_v2.departures%rowtype;
  source_consideration pace_v2.vehicle_considerations%rowtype;
  fixture_captain_id uuid;
  fixture_pair_id uuid;
begin
  select d.* into source_departure
  from pace_v2.departures d
  where d.service_id is not null
  order by d.scheduled_departure_ts,d.id
  limit 1;

  select vc.* into source_consideration
  from pace_v2.vehicle_considerations vc
  join pace_v2.vehicles vehicle
    on vehicle.id=vc.vehicle_id
   and vehicle.active
  where exists (
    select 1
    from pace_v2.vehicle_captain_preferences preference
    join pace_v2.captains captain
      on captain.id=preference.captain_id
     and captain.operator_id=vc.operator_id
     and captain.active
    join pace_v2.captain_vehicle_types eligibility
      on eligibility.captain_id=captain.id
     and eligibility.vehicle_type_id=vehicle.vehicle_type_id
     and eligibility.active
    where preference.vehicle_id=vc.vehicle_id
      and preference.operator_id=vc.operator_id
      and preference.active
  )
  order by vc.id
  limit 1;

  select preference.captain_id into fixture_captain_id
  from pace_v2.vehicle_captain_preferences preference
  join pace_v2.captains captain
    on captain.id=preference.captain_id
   and captain.active
  join pace_v2.vehicles vehicle
    on vehicle.id=source_consideration.vehicle_id
  join pace_v2.captain_vehicle_types eligibility
    on eligibility.captain_id=captain.id
   and eligibility.vehicle_type_id=vehicle.vehicle_type_id
   and eligibility.active
  where preference.vehicle_id=source_consideration.vehicle_id
    and preference.operator_id=source_consideration.operator_id
    and preference.active
  order by preference.priority,preference.captain_id
  limit 1;

  if source_departure.id is null
     or source_consideration.id is null
     or fixture_captain_id is null then
    raise exception 'fixture requires a service departure and an eligible vehicle/captain';
  end if;

  insert into pace_v2.departures(
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
    trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial
  ) values
    ('00000000-0000-0000-0000-000000000001',source_departure.service_id,
     source_departure.route_id,'2097-09-30 14:00:00+00','2097-09-30 15:30:00+00',
     source_departure.trip_timezone,'2097-09-30','2097-09-27 14:00:00+00',
     '2097-09-29 14:00:00+00','cancelled',true),
    ('00000000-0000-0000-0000-000000000002',source_departure.service_id,
     source_departure.route_id,'2097-10-01 15:30:00+00','2097-10-01 16:00:00+00',
     source_departure.trip_timezone,'2097-10-01','2097-09-28 15:30:00+00',
     '2097-09-30 15:30:00+00','cancelled',true),
    ('00000000-0000-0000-0000-000000000003',source_departure.service_id,
     source_departure.route_id,'2097-10-01 16:00:00+00','2097-10-01 17:30:00+00',
     source_departure.trip_timezone,'2097-10-01','2097-09-28 16:00:00+00',
     '2097-09-30 16:00:00+00','cancelled',false);

  insert into pace_v2.vehicle_considerations(
    id,departure_id,vehicle_route_offer_id,vehicle_id,operator_id,status,
    normal_min_seats,max_seats,min_revenue_cents,min_value_threshold_ratio,
    normal_base_seat_price_cents,assigned_seats,assigned_revenue_cents,
    quality_score_snapshot,effective_commission_bps,effective_commission_source,
    engine_version,post_min_discount_enabled,post_min_discount_bps,
    commercial_snapshot_source,below_minimum_operation_mode
  )
  select fixture.id,fixture.departure_id,
    source_consideration.vehicle_route_offer_id,source_consideration.vehicle_id,
    source_consideration.operator_id,'eligible',
    source_consideration.normal_min_seats,source_consideration.max_seats,
    source_consideration.min_revenue_cents,source_consideration.min_value_threshold_ratio,
    source_consideration.normal_base_seat_price_cents,0,0,
    source_consideration.quality_score_snapshot,
    source_consideration.effective_commission_bps,
    source_consideration.effective_commission_source,'captain-reservation-fixture',
    source_consideration.post_min_discount_enabled,
    source_consideration.post_min_discount_bps,
    source_consideration.commercial_snapshot_source,
    source_consideration.below_minimum_operation_mode
  from (values
    ('00000000-0000-0000-0000-000000001001'::uuid,'00000000-0000-0000-0000-000000000001'::uuid),
    ('00000000-0000-0000-0000-000000001002'::uuid,'00000000-0000-0000-0000-000000000002'::uuid)
  ) fixture(id,departure_id);

  insert into pace_v2.captain_duty_reservations(
    departure_id,vehicle_consideration_id,operator_id,vehicle_id,captain_id,
    duty_start_ts,duty_end_ts,state,source,engine_version
  ) values (
    '00000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000001001',
    source_consideration.operator_id,source_consideration.vehicle_id,
    fixture_captain_id,'2097-10-01 14:00:00+00','2097-10-01 16:00:00+00',
    'provisional','fixture','fixture-v1'
  );

  perform set_config('pace_v2.journey_pair_mutation_authorized','on',true);
  insert into pace_v2.journey_pairs(outbound_departure_id,return_departure_id)
  values(
    '00000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000003'
  ) returning id into fixture_pair_id;
  update pace_v2.departures
  set journey_pair_id=fixture_pair_id,
      leg_number=case id
        when '00000000-0000-0000-0000-000000000002'::uuid then 1
        else 2
      end
  where id in (
    '00000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000003'
  );
  perform set_config('pace_v2.journey_pair_mutation_authorized','off',true);
  set constraints all immediate;

  perform set_config('test.captain_reservation_operator_id',source_consideration.operator_id::text,true);
  perform set_config('test.captain_reservation_vehicle_id',source_consideration.vehicle_id::text,true);
  perform set_config('test.captain_reservation_captain_id',fixture_captain_id::text,true);
end
$fixture$;

select extensions.throws_ok(
  format($insert$
    insert into pace_v2.captain_duty_reservations(
      departure_id,vehicle_consideration_id,operator_id,vehicle_id,captain_id,
      duty_start_ts,duty_end_ts,state,source,engine_version
    ) values (
      '00000000-0000-0000-0000-000000000002',
      '00000000-0000-0000-0000-000000001002',%L,%L,%L,
      '2097-10-01 15:30:00+00','2097-10-01 17:00:00+00',
      'provisional','fixture','fixture-v1'
    )
  $insert$,
    current_setting('test.captain_reservation_operator_id'),
    current_setting('test.captain_reservation_vehicle_id'),
    current_setting('test.captain_reservation_captain_id')
  ),
  '23P01',null,
  'one captain cannot hold overlapping active duty ranges'
);

select extensions.lives_ok(
  format($insert$
    insert into pace_v2.captain_duty_reservations(
      departure_id,vehicle_consideration_id,operator_id,vehicle_id,captain_id,
      duty_start_ts,duty_end_ts,state,source,engine_version
    ) values (
      '00000000-0000-0000-0000-000000000002',
      '00000000-0000-0000-0000-000000001002',%L,%L,%L,
      '2097-10-01 16:00:00+00','2097-10-01 17:30:00+00',
      'provisional','fixture','fixture-v1'
    )
  $insert$,
    current_setting('test.captain_reservation_operator_id'),
    current_setting('test.captain_reservation_vehicle_id'),
    current_setting('test.captain_reservation_captain_id')
  ),
  'a captain can serve the next non-overlapping duty'
);

select extensions.is(
  upper(pace_v2.captain_reservation_window(
    '00000000-0000-0000-0000-000000000002'
  )),
  '2097-10-01 18:00:00+00'::timestamptz,
  'paired duty ends at return arrival plus thirty minutes'
);

select extensions.ok(
  not has_table_privilege('anon','pace_v2.captain_duty_reservations','select')
  and not has_table_privilege('authenticated','pace_v2.captain_duty_reservations','select'),
  'client roles cannot read captain reservations'
);

create temporary table captain_paid_allocation_results(
  result_name text primary key,
  result_value text not null
) on commit drop;

do $paid_allocation_fixture$
declare
  source_departure pace_v2.departures%rowtype;
  source_operator_id uuid;
  source_vehicle_ids uuid[];
  first_departure_id uuid:=gen_random_uuid();
  second_departure_id uuid:=gen_random_uuid();
  first_booking_id uuid:=gen_random_uuid();
  companion_booking_id uuid:=gen_random_uuid();
  losing_booking_id uuid:=gen_random_uuid();
  first_result record;
  companion_result record;
  losing_result record;
  active_count integer;
begin
  select departure.* into source_departure
  from pace_v2.departures departure
  where exists (
    select 1
    from pace_v2.vehicle_considerations consideration
    join pace_v2.operators fleet_operator
      on fleet_operator.id=consideration.operator_id
     and fleet_operator.active
    where consideration.departure_id=departure.id
    group by consideration.operator_id
    having count(distinct consideration.vehicle_id)>=2
       and (
         select count(*)
         from pace_v2.captains captain
         where captain.operator_id=consideration.operator_id
           and captain.active
       )=1
  )
  order by departure.scheduled_departure_ts,departure.id
  limit 1;

  select consideration.operator_id,
         (array_agg(distinct consideration.vehicle_id order by consideration.vehicle_id))
           [1:2]
  into source_operator_id,source_vehicle_ids
  from pace_v2.vehicle_considerations consideration
  where consideration.departure_id=source_departure.id
  group by consideration.operator_id
  having count(distinct consideration.vehicle_id)>=2
     and (
       select count(*)
       from pace_v2.captains captain
       where captain.operator_id=consideration.operator_id
         and captain.active
     )=1
  order by consideration.operator_id
  limit 1;

  if source_departure.id is null
     or cardinality(source_vehicle_ids)<>2 then
    raise exception 'fixture requires one operator with two vehicles and one captain';
  end if;

  -- Production permits only one commercial departure per service/day. This
  -- rollback-only fixture deliberately creates two simultaneous services to
  -- exercise cross-journey captain contention, so suspend that unrelated
  -- design-time index for the transaction; the outer rollback restores it.
  drop index pace_v2.ux_departures_service_local_date;

  insert into pace_v2.departures(
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
    trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial
  ) values
    (first_departure_id,source_departure.service_id,source_departure.route_id,
     '2098-10-01 14:00:00+00','2098-10-01 15:30:00+00',
     source_departure.trip_timezone,'2098-10-01','2098-09-28 14:00:00+00',
     '2098-09-30 14:00:00+00','selling',true),
    (second_departure_id,source_departure.service_id,source_departure.route_id,
     '2098-10-01 14:15:00+00','2098-10-01 15:45:00+00',
     source_departure.trip_timezone,'2098-10-02','2098-09-28 14:15:00+00',
     '2098-09-30 14:15:00+00','selling',true);

  perform pace_v2.refresh_vehicle_considerations(first_departure_id,'paid-captain-fixture');
  perform pace_v2.refresh_vehicle_considerations(second_departure_id,'paid-captain-fixture');

  update pace_v2.vehicle_considerations consideration
  set status='withdrawn'
  where consideration.departure_id=first_departure_id
    and consideration.vehicle_id<>source_vehicle_ids[1];
  update pace_v2.vehicle_considerations consideration
  set status='withdrawn'
  where consideration.departure_id=second_departure_id
    and consideration.vehicle_id<>source_vehicle_ids[2];

  if not exists(
    select 1 from pace_v2.vehicle_considerations consideration
    where consideration.departure_id=first_departure_id
      and consideration.vehicle_id=source_vehicle_ids[1]
  ) or not exists(
    select 1 from pace_v2.vehicle_considerations consideration
    where consideration.departure_id=second_departure_id
      and consideration.vehicle_id=source_vehicle_ids[2]
  ) then
    raise exception 'fixture vehicles were not eligible on cloned departures';
  end if;

  insert into pace_v2.bookings(
    id,departure_id,route_id,customer_name,seats,status,currency,
    unit_price_cents,total_price_cents,commercial_snapshot
  ) values
    (first_booking_id,first_departure_id,source_departure.route_id,
     'Paid captain fixture one',1,'pending_payment','USD',10000,10000,'{}'),
    (companion_booking_id,first_departure_id,source_departure.route_id,
     'Paid captain fixture companion',1,'pending_payment','USD',10000,10000,'{}'),
    (losing_booking_id,second_departure_id,source_departure.route_id,
     'Paid captain fixture loser',1,'pending_payment','USD',10000,10000,'{}');

  select * into first_result
  from pace_v2.allocate_paid_booking(first_booking_id);
  select * into companion_result
  from pace_v2.allocate_paid_booking(companion_booking_id);
  select * into losing_result
  from pace_v2.allocate_paid_booking(losing_booking_id);

  insert into captain_paid_allocation_results(result_name,result_value) values
    ('first_departure_id',first_departure_id::text),
    ('first_booking_id',first_booking_id::text),
    ('first_result',first_result.result_status),
    ('companion_result',companion_result.result_status),
    ('losing_result',losing_result.result_status),
    ('losing_booked_count',(
      select count(*)::text from pace_v2.bookings booking
      where booking.id=losing_booking_id and booking.status='booked'
    )),
    ('initial_active_count',(
      select count(*)::text
      from pace_v2.captain_duty_reservations reservation
      where reservation.departure_id in(first_departure_id,second_departure_id)
        and reservation.state='provisional'
    ));

  perform pace_v2.cancel_booking_and_request_refund(
    first_booking_id,0,'paid captain fixture','admin'
  );
  select count(*) into active_count
  from pace_v2.captain_duty_reservations reservation
  where reservation.departure_id=first_departure_id
    and reservation.state='provisional';
  insert into captain_paid_allocation_results values(
    'after_first_cancel_active_count',active_count::text
  );

  perform pace_v2.cancel_booking_and_request_refund(
    companion_booking_id,0,'paid captain fixture','admin'
  );
  select count(*) into active_count
  from pace_v2.captain_duty_reservations reservation
  where reservation.departure_id=first_departure_id
    and reservation.state='provisional';
  insert into captain_paid_allocation_results values(
    'after_final_cancel_active_count',active_count::text
  );
end
$paid_allocation_fixture$;

select extensions.is(
  (select result_value from captain_paid_allocation_results where result_name='first_result'),
  'allocated','first paid demand reserves a captain'
);
select extensions.is(
  (select result_value from captain_paid_allocation_results where result_name='companion_result'),
  'allocated','a companion booking reuses the vehicle captain claim'
);
select extensions.ok(
  (select result_value from captain_paid_allocation_results where result_name='losing_result')
    in('unavailable','sold_out_for_party'),
  'overlapping paid demand without another captain is unavailable'
);
select extensions.is(
  (select result_value from captain_paid_allocation_results where result_name='initial_active_count'),
  '1','only one overlapping paid vehicle demand can reserve the captain'
);
select extensions.is(
  (select result_value from captain_paid_allocation_results where result_name='losing_booked_count'),
  '0','the losing payment cannot become an unstaffed booking'
);
select extensions.is(
  (select result_value from captain_paid_allocation_results where result_name='after_first_cancel_active_count'),
  '1','cancelling one of several bookings preserves the captain claim'
);
select extensions.is(
  (select result_value from captain_paid_allocation_results where result_name='after_final_cancel_active_count'),
  '0','cancelling the final qualifying allocation releases the captain claim'
);

create temporary table captain_t72_results(
  result_name text primary key,
  result_value text not null
) on commit drop;

do $t72_captain_fixture$
declare
  source_departure pace_v2.departures%rowtype;
  source_operator_id uuid;
  source_vehicle_ids uuid[];
  test_departure_id uuid:=gen_random_uuid();
  added_captain_id uuid:=gen_random_uuid();
  consideration record;
  booking_id uuid;
  allocation_unit_price integer;
  discarded_vehicle_id uuid;
  discarded_count_before integer;
  process_result jsonb;
  t24_result record;
begin
  select departure.* into source_departure
  from pace_v2.departures departure
  where exists (
    select 1
    from pace_v2.vehicle_considerations candidate
    join pace_v2.vehicle_route_offers route_offer
      on route_offer.id=candidate.vehicle_route_offer_id
     and route_offer.preferred_captain_id is null
    where candidate.departure_id=departure.id
    group by candidate.operator_id
    having count(distinct candidate.vehicle_id)>=3
       and (
         select count(*) from pace_v2.captains captain
         where captain.operator_id=candidate.operator_id and captain.active
       )=1
  )
  order by departure.scheduled_departure_ts,departure.id
  limit 1;

  select candidate.operator_id,
         (array_agg(distinct candidate.vehicle_id order by candidate.vehicle_id))[1:3]
  into source_operator_id,source_vehicle_ids
  from pace_v2.vehicle_considerations candidate
  join pace_v2.vehicle_route_offers route_offer
    on route_offer.id=candidate.vehicle_route_offer_id
   and route_offer.preferred_captain_id is null
  where candidate.departure_id=source_departure.id
  group by candidate.operator_id
  having count(distinct candidate.vehicle_id)>=3
     and (
       select count(*) from pace_v2.captains captain
       where captain.operator_id=candidate.operator_id and captain.active
     )=1
  order by candidate.operator_id
  limit 1;

  if source_departure.id is null or cardinality(source_vehicle_ids)<>3 then
    raise exception 'fixture requires three vehicles owned by a one-captain operator';
  end if;

  insert into pace_v2.captains(
    id,operator_id,first_name,last_name,active
  ) values(
    added_captain_id,source_operator_id,'Second','Fixture Captain',true
  );

  insert into pace_v2.captain_vehicle_types(captain_id,vehicle_type_id,active,note)
  select distinct added_captain_id,vehicle.vehicle_type_id,true,'T-72 fixture'
  from pace_v2.vehicles vehicle
  where vehicle.id=any(source_vehicle_ids);

  insert into pace_v2.vehicle_captain_preferences(
    operator_id,vehicle_id,captain_id,priority,active
  )
  select source_operator_id,listed.vehicle_id,added_captain_id,2,true
  from unnest(source_vehicle_ids) listed(vehicle_id);

  insert into pace_v2.departures(
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
    trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial
  ) values(
    test_departure_id,source_departure.service_id,source_departure.route_id,
    '2099-10-01 14:00:00+00','2099-10-01 16:00:00+00',
    source_departure.trip_timezone,'2099-10-01',now()-interval '1 minute',
    '2099-09-30 14:00:00+00','selling',true
  );

  perform pace_v2.refresh_vehicle_considerations(test_departure_id,'t72-captain-fixture');
  update pace_v2.vehicle_considerations candidate
  set status='withdrawn'
  where candidate.departure_id=test_departure_id
    and not(candidate.vehicle_id=any(source_vehicle_ids));

  for consideration in
    select candidate.*
    from pace_v2.vehicle_considerations candidate
    where candidate.departure_id=test_departure_id
      and candidate.vehicle_id=any(source_vehicle_ids)
    order by candidate.vehicle_id
  loop
    booking_id:=gen_random_uuid();
    allocation_unit_price:=greatest(
      consideration.normal_base_seat_price_cents,
      ceil(consideration.min_revenue_cents::numeric/consideration.max_seats)::integer
    );
    insert into pace_v2.bookings(
      id,departure_id,route_id,customer_name,seats,status,currency,
      unit_price_cents,total_price_cents,preliminary_vehicle_id,
      commercial_snapshot
    ) values(
      booking_id,test_departure_id,source_departure.route_id,
      'T-72 captain fixture',consideration.max_seats,'booked','USD',
      allocation_unit_price,allocation_unit_price*consideration.max_seats,
      consideration.vehicle_id,
      jsonb_build_object('quote_snapshot',jsonb_build_object(
        'discount_applied',true,
        'vehicle_consideration_id',consideration.id
      ))
    );
    insert into pace_v2.booking_allocations(
      booking_id,departure_id,vehicle_consideration_id,vehicle_id,status,
      seats,unit_price_cents,allocation_reason
    ) values(
      booking_id,test_departure_id,consideration.id,consideration.vehicle_id,
      'confirmed',consideration.max_seats,allocation_unit_price,
      'T-72 captain fixture'
    );
  end loop;

  if (
    select count(*) from pace_v2.vehicle_considerations candidate
    where candidate.departure_id=test_departure_id
      and candidate.vehicle_id=any(source_vehicle_ids)
  )<>3 then
    raise exception 'fixture did not create exactly three target considerations';
  end if;

  update pace_v2.departures
  set t72_ts=now()-interval '1 minute'
  where id=test_departure_id;
  perform pace_v2.refresh_consideration_totals(test_departure_id);
  process_result:=pace_v2.process_departure_t72(
    test_departure_id,'t72-captain-fixture',true
  );

  select candidate.vehicle_id into discarded_vehicle_id
  from pace_v2.vehicle_considerations candidate
  where candidate.departure_id=test_departure_id
    and candidate.status='discarded_t72'
    and candidate.captain_resource_reason='captain_conflict'
  order by candidate.id
  limit 1;

  select count(*) into discarded_count_before
  from pace_v2.vehicle_considerations candidate
  where candidate.departure_id=test_departure_id
    and candidate.status='discarded_t72'
    and candidate.captain_resource_reason='captain_conflict';

  update pace_v2.vehicle_considerations candidate
  set status='under_consideration',captain_resource_reason=null,updated_at=now()
  where candidate.departure_id=test_departure_id
    and candidate.vehicle_id=discarded_vehicle_id;
  select * into t24_result
  from pace_v2.confirm_departure_t24(
    test_departure_id,true,'t24-captain-shortage-fixture'
  );

  insert into captain_t72_results(result_name,result_value) values
    ('held_count',(
      select count(*)::text from pace_v2.captain_duty_reservations reservation
      where reservation.departure_id=test_departure_id
        and reservation.state='held_t72'
    )),
    ('discarded_count',discarded_count_before::text),
    ('departure_status',(
      select departure.status::text from pace_v2.departures departure
      where departure.id=test_departure_id
    )),
    ('alert_count',(
      select count(*)::text from pace_v2.operational_alerts alert
      where alert.exception_key='captain_resource_shortage:'||test_departure_id::text
        and alert.severity='high' and alert.resolved_at is null
    )),
    ('decision_count',(
      select count(*)::text from pace_v2.allocation_decisions decision
      where decision.departure_id=test_departure_id
        and decision.decision_reason_code='T72_CAPTAIN_CONFLICT'
    )),
    ('t24_shortage_outcome',t24_result.outcome),
    ('t24_confirmed_allocation_count',(
      select count(*)::text from pace_v2.confirmed_allocations allocation
      where allocation.departure_id=test_departure_id
    )),
    ('email_resource_gate',coalesce((
      select (
        jsonb_array_length(notification.metadata->'vehicles')=2
        and not exists(
          select 1
          from jsonb_array_elements(notification.metadata->'vehicles') resource
          where resource->>'vehicleName'=(
            select vehicle.name from pace_v2.vehicles vehicle
            where vehicle.id=discarded_vehicle_id
          )
        )
      )::text
      from pace_v2.notifications notification
      where notification.departure_id=test_departure_id
        and notification.channel='email'
        and notification.template_code='T72_UNDER_CONSIDERATION'
      order by notification.created_at desc
      limit 1
    ),'false'));
end
$t72_captain_fixture$;

select extensions.is(
  (select result_value from captain_t72_results where result_name='held_count'),
  '2','T-72 holds one distinct captain per staffable vehicle'
);
select extensions.is(
  (select result_value from captain_t72_results where result_name='discarded_count'),
  '1','the unstaffable vehicle is removed as a resource decision'
);
select extensions.is(
  (select result_value from captain_t72_results where result_name='departure_status'),
  'at_risk','an uncovered paid party leaves the journey at risk'
);
select extensions.is(
  (select result_value from captain_t72_results where result_name='alert_count'),
  '1','captain shortage creates one high-priority operational alert'
);
select extensions.is(
  (select result_value from captain_t72_results where result_name='decision_count'),
  '1','captain conflict is recorded as a T-72 allocation decision'
);
select extensions.is(
  (select result_value from captain_t72_results where result_name='email_resource_gate'),
  'true','the T-72 operator email contains only held vehicles'
);

select extensions.is(
  (select result_value from captain_t72_results where result_name='t24_shortage_outcome'),
  'at_risk_manual_review','T-24 captain shortage returns manual review'
);
select extensions.is(
  (select result_value from captain_t72_results where result_name='t24_confirmed_allocation_count'),
  '0','T-24 captain shortage creates no confirmed allocations'
);

create temporary table captain_t24_results(
  result_name text primary key,
  result_value text not null
) on commit drop;

do $t24_captain_fixture$
declare
  test_departure_id uuid:=(
    select result_value::uuid from captain_paid_allocation_results
    where result_name='first_departure_id'
  );
  test_booking_id uuid:=(
    select result_value::uuid from captain_paid_allocation_results
    where result_name='first_booking_id'
  );
  consideration_id uuid;
  held_captain_id uuid;
  alternate_captain_id uuid;
  fixture_operator_id uuid;
  fixture_vehicle_id uuid;
  fixture_vehicle_type_id uuid;
  confirmed_captain_id uuid;
  assignment_matches boolean;
  confirmation_result record;
begin
  update pace_v2.bookings
  set status='booked',updated_at=now()
  where id=test_booking_id;
  update pace_v2.booking_allocations
  set status='confirmed'
  where booking_id=test_booking_id;
  perform pace_v2.refresh_consideration_totals(test_departure_id);

  select allocation.vehicle_consideration_id into consideration_id
  from pace_v2.booking_allocations allocation
  where allocation.booking_id=test_booking_id
  order by allocation.allocated_at desc
  limit 1;

  update pace_v2.vehicle_considerations
  set status='under_consideration',updated_at=now()
  where id=consideration_id;

  perform * from pace_v2.reconcile_departure_captain_reservations(
    test_departure_id,'held_t72','t24-rematch-fixture'
  );
  select reservation.captain_id into held_captain_id
  from pace_v2.captain_duty_reservations reservation
  where reservation.vehicle_consideration_id=consideration_id
    and reservation.state='held_t72';

  select consideration.operator_id,consideration.vehicle_id,vehicle.vehicle_type_id
  into fixture_operator_id,fixture_vehicle_id,fixture_vehicle_type_id
  from pace_v2.vehicle_considerations consideration
  join pace_v2.vehicles vehicle on vehicle.id=consideration.vehicle_id
  where consideration.id=consideration_id;

  insert into pace_v2.captains(
    operator_id,first_name,last_name,email,active
  ) values(
    fixture_operator_id,'Rollback','Alternate Captain',
    'captain-rematch+'||replace(gen_random_uuid()::text,'-','')||'@example.invalid',true
  ) returning id into alternate_captain_id;
  insert into pace_v2.captain_vehicle_types(
    captain_id,vehicle_type_id,active
  ) values(alternate_captain_id,fixture_vehicle_type_id,true);

  update pace_v2.vehicle_route_offers route_offer
  set preferred_captain_id=null
  from pace_v2.vehicle_considerations consideration
  where consideration.id=consideration_id
    and route_offer.id=consideration.vehicle_route_offer_id;
  update pace_v2.vehicle_captain_preferences
  set active=true,priority=1,updated_at=now()
  where vehicle_id=fixture_vehicle_id and captain_id=held_captain_id;
  insert into pace_v2.vehicle_captain_preferences(
    operator_id,vehicle_id,captain_id,priority,active
  )
  select fixture_operator_id,fixture_vehicle_id,held_captain_id,1,true
  where not exists(
    select 1 from pace_v2.vehicle_captain_preferences preference
    where preference.vehicle_id=fixture_vehicle_id
      and preference.captain_id=held_captain_id
  );
  insert into pace_v2.vehicle_captain_preferences(
    operator_id,vehicle_id,captain_id,priority,active
  ) values(
    fixture_operator_id,fixture_vehicle_id,alternate_captain_id,2,true
  );

  update pace_v2.captains set active=false where id=held_captain_id;
  select * into confirmation_result
  from pace_v2.confirm_departure_t24(
    test_departure_id,true,'t24-rematch-fixture'
  );

  select reservation.captain_id,
         assignment.captain_id=reservation.captain_id
  into confirmed_captain_id,assignment_matches
  from pace_v2.captain_duty_reservations reservation
  join pace_v2.captain_assignments assignment
    on assignment.id=reservation.captain_assignment_id
   and assignment.active
  where reservation.vehicle_consideration_id=consideration_id
    and reservation.state='confirmed_t24';

  update pace_v2.captains set active=true where id=held_captain_id;
  update pace_v2.departures set status='completed' where id=test_departure_id;

  insert into captain_t24_results(result_name,result_value) values
    ('confirmation_outcome',confirmation_result.outcome),
    ('captain_rematched',(confirmed_captain_id<>held_captain_id)::text),
    ('assignment_matches',assignment_matches::text),
    ('released_count',(
      select count(*)::text
      from pace_v2.captain_duty_reservations reservation
      where reservation.departure_id=test_departure_id
        and reservation.state='released'
        and reservation.release_reason='departure-completed'
    ));
end
$t24_captain_fixture$;

select extensions.is(
  (select result_value from captain_t24_results where result_name='captain_rematched'),
  'true','an ineligible held captain is deterministically rematched at T-24'
);
select extensions.is(
  (select result_value from captain_t24_results where result_name='assignment_matches'),
  'true','T-24 assignment uses the confirmed reservation captain'
);
select extensions.is(
  (select result_value from captain_t24_results where result_name='released_count'),
  '1','final one-way completion releases the confirmed captain reservation'
);

create temporary table captain_backfill_results(
  result_name text primary key,
  result_value text not null
) on commit drop;

do $captain_backfill_fixture$
declare
  source_departure pace_v2.departures%rowtype;
  source_consideration pace_v2.vehicle_considerations%rowtype;
  source_allocation pace_v2.confirmed_allocations%rowtype;
  fixture_captain_id uuid;
  first_departure_id uuid:=gen_random_uuid();
  second_departure_id uuid:=gen_random_uuid();
  first_consideration_id uuid:=gen_random_uuid();
  second_consideration_id uuid:=gen_random_uuid();
  first_allocation_id uuid;
  second_allocation_id uuid;
  first_assignment_id uuid;
  second_assignment_id uuid;
begin
  select departure.* into source_departure
  from pace_v2.departures departure
  where departure.service_id is not null
  order by departure.id
  limit 1;

  select consideration.*
  into source_consideration
  from pace_v2.vehicle_considerations consideration
  join pace_v2.vehicles vehicle
    on vehicle.id=consideration.vehicle_id and vehicle.active
  join pace_v2.vehicle_captain_preferences preference
    on preference.vehicle_id=consideration.vehicle_id
   and preference.operator_id=consideration.operator_id
   and preference.active
  join pace_v2.captains captain
    on captain.id=preference.captain_id
   and captain.operator_id=consideration.operator_id
   and captain.active
  join pace_v2.captain_vehicle_types eligibility
    on eligibility.captain_id=captain.id
   and eligibility.vehicle_type_id=vehicle.vehicle_type_id
   and eligibility.active
  order by preference.priority,consideration.id
  limit 1;

  select preference.captain_id
  into fixture_captain_id
  from pace_v2.vehicle_captain_preferences preference
  join pace_v2.captains captain
    on captain.id=preference.captain_id
   and captain.operator_id=source_consideration.operator_id
   and captain.active
  join pace_v2.vehicles vehicle
    on vehicle.id=source_consideration.vehicle_id
  join pace_v2.captain_vehicle_types eligibility
    on eligibility.captain_id=captain.id
   and eligibility.vehicle_type_id=vehicle.vehicle_type_id
   and eligibility.active
  where preference.vehicle_id=source_consideration.vehicle_id
    and preference.operator_id=source_consideration.operator_id
    and preference.active
  order by preference.priority,preference.captain_id
  limit 1;

  select allocation.* into source_allocation
  from pace_v2.confirmed_allocations allocation
  order by allocation.created_at,allocation.id
  limit 1;

  if source_departure.id is null or source_consideration.id is null
     or source_allocation.id is null or fixture_captain_id is null then
    raise exception 'backfill fixture requires seeded departure, consideration, allocation and captain';
  end if;

  -- Seed a pre-migration conflict that normal current writes correctly reject.
  -- Both trigger changes are transaction-local because this fixture rolls back.
  alter table pace_v2.confirmed_allocations
    disable trigger confirmed_allocations_require_eligible_captain;
  alter table pace_v2.captain_assignments
    disable trigger captain_assignments_preserve_eligible_allocation_captain;
  set constraints all immediate;
  drop index pace_v2.ux_departures_service_local_date;

  insert into pace_v2.departures(
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
    trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial
  ) values
    (first_departure_id,source_departure.service_id,source_departure.route_id,
     '2098-01-01 10:00:00+00','2098-01-01 12:00:00+00','UTC','2098-01-01',
     '2097-12-29 10:00:00+00','2097-12-31 10:00:00+00','confirmed',true),
    (second_departure_id,source_departure.service_id,source_departure.route_id,
     '2098-01-01 11:00:00+00','2098-01-01 13:00:00+00','UTC','2098-01-01',
     '2097-12-29 11:00:00+00','2097-12-31 11:00:00+00','confirmed',true);

  insert into pace_v2.vehicle_considerations(
    id,departure_id,vehicle_route_offer_id,vehicle_id,operator_id,status,
    normal_min_seats,max_seats,min_revenue_cents,min_value_threshold_ratio,
    normal_base_seat_price_cents,assigned_seats,assigned_revenue_cents,
    quality_score_snapshot,effective_commission_bps,effective_commission_source,
    engine_version,post_min_discount_enabled,post_min_discount_bps,
    commercial_snapshot_source,below_minimum_operation_mode
  )
  select fixture.consideration_id,fixture.departure_id,
    source_consideration.vehicle_route_offer_id,source_consideration.vehicle_id,
    source_consideration.operator_id,'under_consideration',
    source_consideration.normal_min_seats,source_consideration.max_seats,
    source_consideration.min_revenue_cents,source_consideration.min_value_threshold_ratio,
    source_consideration.normal_base_seat_price_cents,1,1000,
    source_consideration.quality_score_snapshot,
    source_consideration.effective_commission_bps,
    source_consideration.effective_commission_source,'captain-backfill-fixture',
    source_consideration.post_min_discount_enabled,
    source_consideration.post_min_discount_bps,
    source_consideration.commercial_snapshot_source,
    source_consideration.below_minimum_operation_mode
  from (values
    (first_consideration_id,first_departure_id),
    (second_consideration_id,second_departure_id)
  ) fixture(consideration_id,departure_id);

  insert into pace_v2.confirmed_allocations(
    departure_id,vehicle_id,operator_id,consideration_id,confirmed_at,confirmed_by,
    operator_journey_value_cents,effective_commission_bps,
    pace_shuttles_commission_cents,operator_net_before_adjustments_cents,
    status,completed_at,created_at
  )
  select fixture.departure_id,source_consideration.vehicle_id,
    source_consideration.operator_id,fixture.consideration_id,now(),'backfill-fixture',
    source_allocation.operator_journey_value_cents,
    source_allocation.effective_commission_bps,
    source_allocation.pace_shuttles_commission_cents,
    source_allocation.operator_net_before_adjustments_cents,
    'confirmed',null,fixture.created_at
  from (values
    (first_departure_id,first_consideration_id,'2097-12-31 09:00:00+00'::timestamptz),
    (second_departure_id,second_consideration_id,'2097-12-31 09:01:00+00'::timestamptz)
  ) fixture(departure_id,consideration_id,created_at)
  order by fixture.created_at;

  select allocation.id into first_allocation_id
  from pace_v2.confirmed_allocations allocation
  where allocation.consideration_id=first_consideration_id;
  select allocation.id into second_allocation_id
  from pace_v2.confirmed_allocations allocation
  where allocation.consideration_id=second_consideration_id;

  insert into pace_v2.captain_assignments(
    confirmed_allocation_id,captain_id,assignment_source,active
  ) values
    (first_allocation_id,fixture_captain_id,'auto',true),
    (second_allocation_id,fixture_captain_id,'auto',true);

  select assignment.id into first_assignment_id
  from pace_v2.captain_assignments assignment
  where assignment.confirmed_allocation_id=first_allocation_id and assignment.active;
  select assignment.id into second_assignment_id
  from pace_v2.captain_assignments assignment
  where assignment.confirmed_allocation_id=second_allocation_id and assignment.active;

  perform * from pace_v2.backfill_captain_duty_reservations();
  perform * from pace_v2.backfill_captain_duty_reservations();

  insert into captain_backfill_results(result_name,result_value) values
    ('active_assignment_count',(
      select count(*)::text from pace_v2.captain_assignments assignment
      where assignment.id in(first_assignment_id,second_assignment_id)
        and assignment.active
    )),
    ('confirmed_reservation_count',(
      select count(*)::text from pace_v2.captain_duty_reservations reservation
      where reservation.confirmed_allocation_id in(first_allocation_id,second_allocation_id)
        and reservation.state='confirmed_t24'
    )),
    ('conflict_alert_count',(
      select count(*)::text from pace_v2.operational_alerts alert
      where alert.exception_key='captain_reservation_backfill_conflict:'||second_allocation_id::text
        and alert.severity='high' and alert.resolved_at is null
    )),
    ('conflicting_assignment_unchanged',(
      select (assignment.captain_id=fixture_captain_id and assignment.active)::text
      from pace_v2.captain_assignments assignment
      where assignment.id=second_assignment_id
    ));
end
$captain_backfill_fixture$;

select extensions.is(
  (select result_value from captain_backfill_results where result_name='active_assignment_count'),
  '2','backfill never deactivates either legacy confirmed captain assignment'
);
select extensions.is(
  (select result_value from captain_backfill_results where result_name='confirmed_reservation_count'),
  '1','backfill creates only the first conflict-free confirmed reservation'
);
select extensions.is(
  (select result_value from captain_backfill_results where result_name='conflict_alert_count'),
  '1','backfill records one stable high-priority alert for the overlapping assignment'
);
select extensions.is(
  (select result_value from captain_backfill_results where result_name='conflicting_assignment_unchanged'),
  'true','backfill preserves the conflicting captain identity and active state'
);

select * from extensions.finish();
rollback;
