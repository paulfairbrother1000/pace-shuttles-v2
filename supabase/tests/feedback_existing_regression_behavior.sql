-- Seed two genuinely completed synthetic journeys in distinct countries to
-- exercise the original broad feedback regression fixture, never production.
begin;
\ir fixtures/completion_feedback.sql
select pg_temp.complete_fixture();
set constraints all deferred;
-- Synthetic, transaction-scoped fixture. Never run lifecycle tests on production.
create or replace function pg_temp.fid(n integer) returns uuid language sql immutable as
$$ select ('f2000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid $$;
insert into auth.users(id,email,created_at,updated_at,is_sso_user,is_anonymous)
select pg_temp.fid(n),'fixture-second-'||n||'@example.invalid',now(),now(),false,false from generate_series(100,104) n;
insert into pace_v2.profiles(user_id,platform_role)
select pg_temp.fid(n),case when n=100 then 'site_admin' else 'customer' end::pace_v2.platform_role from generate_series(100,104) n;
select set_config('request.jwt.claim.sub',pg_temp.fid(100)::text,true);
insert into pace_v2.countries(id,name,timezone) values(pg_temp.fid(1),'Second Fixture Antigua','America/Antigua');
insert into pace_v2.pickup_points(id,country_id,name) values(pg_temp.fid(2),pg_temp.fid(1),'Second Fixture pickup');
insert into pace_v2.destinations(id,country_id,name) values(pg_temp.fid(3),pg_temp.fid(1),'Second Fixture destination');
insert into pace_v2.routes(id,country_id,pickup_id,destination_id,trip_timezone,route_name)
values(pg_temp.fid(4),pg_temp.fid(1),pg_temp.fid(2),pg_temp.fid(3),'America/Antigua','Second Fixture route');
insert into pace_v2.services(id,route_id,timezone,days_of_week,departure_time,active)
values(pg_temp.fid(5),pg_temp.fid(4),'America/Antigua',array[1,2,3,4,5,6,7]::smallint[],'10:00',false);
insert into pace_v2.vehicle_types(id,code,name,default_capacity) values(pg_temp.fid(6),'second_fixture_boat','Second Fixture Boat',10);
insert into pace_v2.route_vehicle_types(route_id,vehicle_type_id,effective_from) values(pg_temp.fid(4),pg_temp.fid(6),now()-interval '1 year');
insert into pace_v2.operators(id,name,country_id,active) values(pg_temp.fid(7),'Second Fixture Operator',pg_temp.fid(1),false);
insert into pace_v2.operator_vehicle_types(operator_id,vehicle_type_id,status) values(pg_temp.fid(7),pg_temp.fid(6),'approved');
insert into pace_v2.captains(id,operator_id,auth_user_id,first_name,last_name,email)
select pg_temp.fid(n),pg_temp.fid(7),pg_temp.fid(n+94),'Fixture','Captain '||n,'fixture-second-'||(n+94)||'@example.invalid' from generate_series(8,9) n;
insert into pace_v2.captain_vehicle_types(captain_id,vehicle_type_id)
select pg_temp.fid(n),pg_temp.fid(6) from generate_series(8,9) n;
insert into pace_v2.vehicles(id,operator_id,vehicle_type_id,name,capacity_seats,capacity_source,default_min_seats,default_max_seats,default_min_revenue_cents)
select pg_temp.fid(n),pg_temp.fid(7),pg_temp.fid(6),'Second Fixture Boat '||n,10,'operator_verified',2,10,2000 from generate_series(10,11) n;
insert into pace_v2.vehicle_captain_preferences(operator_id,vehicle_id,captain_id,priority)
select pg_temp.fid(7),pg_temp.fid(n),pg_temp.fid(n-2),1 from generate_series(10,11) n;
update pace_v2.operators set active=true where id=pg_temp.fid(7);
insert into pace_v2.vehicle_route_offers(id,vehicle_id,route_id,service_id,min_seats,max_seats,min_revenue_cents)
select pg_temp.fid(n+10),pg_temp.fid(n),pg_temp.fid(4),pg_temp.fid(5),2,10,2000 from generate_series(10,11) n;
select set_config('pace_v2.journey_pair_mutation_authorized','on',true);
insert into pace_v2.departures(id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,trip_timezone,local_departure_date,t72_ts,t24_ts,status,is_commercial)
values
 (pg_temp.fid(30),pg_temp.fid(5),pg_temp.fid(4),now()-interval '1 hour',now()+interval '1 hour','America/Antigua',(now() at time zone 'America/Antigua')::date,now()-interval '73 hours',now()-interval '25 hours','confirmed',true),
 (pg_temp.fid(31),pg_temp.fid(5),pg_temp.fid(4),now()+interval '2 hours',now()+interval '3 hours','America/Antigua',(now() at time zone 'America/Antigua')::date,now()-interval '70 hours',now()-interval '22 hours','confirmed',false);
insert into pace_v2.journey_pairs(id,outbound_departure_id,return_departure_id) values(pg_temp.fid(32),pg_temp.fid(30),pg_temp.fid(31));
update pace_v2.departures set journey_pair_id=pg_temp.fid(32),leg_number=case id when pg_temp.fid(30) then 1 else 2 end where id in(pg_temp.fid(30),pg_temp.fid(31));
select set_config('pace_v2.journey_pair_mutation_authorized','off',true);
insert into pace_v2.vehicle_considerations(id,departure_id,vehicle_route_offer_id,vehicle_id,operator_id,status,normal_min_seats,max_seats,min_revenue_cents,normal_base_seat_price_cents,engine_version,commercial_snapshot_source,commercial_snapshot_locked_at)
select pg_temp.fid(n+30),pg_temp.fid(30),pg_temp.fid(n+10),pg_temp.fid(n),pg_temp.fid(7),'confirmed',2,10,2000,1000,'fixture','route_offer',now() from generate_series(10,11) n;
insert into pace_v2.confirmed_allocations(id,departure_id,vehicle_id,operator_id,consideration_id,confirmed_by,operator_journey_value_cents,effective_commission_bps,pace_shuttles_commission_cents,operator_net_before_adjustments_cents)
select pg_temp.fid(n+40),pg_temp.fid(30),pg_temp.fid(n),pg_temp.fid(7),pg_temp.fid(n+30),'fixture',2000,1000,200,1800 from generate_series(10,11) n;
insert into pace_v2.captain_assignments(id,confirmed_allocation_id,captain_id,assignment_source)
select pg_temp.fid(n+50),pg_temp.fid(n+40),pg_temp.fid(n-2),'auto' from generate_series(10,11) n;
insert into pace_v2.orders(id,customer_user_id,customer_email,customer_name,subtotal_cents,total_cents,payment_status,paid_at,fulfillment_status)
select pg_temp.fid(n+60),pg_temp.fid(101),'fixture-second-101@example.invalid','Second Fixture Customer',2000,2000,'paid',now(),'booked' from generate_series(10,11) n;
insert into pace_v2.bookings(id,order_id,departure_id,route_id,customer_name,seats,status,unit_price_cents,total_price_cents,paid_at)
select pg_temp.fid(n+70),pg_temp.fid(n+60),pg_temp.fid(30),pg_temp.fid(4),'Second Fixture Customer',2,'confirmed',1000,2000,now() from generate_series(10,11) n;
insert into pace_v2.booking_allocations(booking_id,departure_id,vehicle_consideration_id,vehicle_id,status,seats,unit_price_cents)
select pg_temp.fid(n+70),pg_temp.fid(30),pg_temp.fid(n+30),pg_temp.fid(n),'confirmed',2,1000 from generate_series(10,11) n;
insert into pace_v2.ledger_accounts(account_code,account_name,account_type,operator_id,currency)
values('FIXTURE-SECOND-OP','Second Fixture payable','operator_payable',pg_temp.fid(7),'USD');
insert into pace_v2.ledger_accounts(account_code,account_name,account_type,currency)
values('PS-COMMISSION','Second Fixture commission','pace_shuttles_commission_revenue','USD'),('PS-CLEARING','Second Fixture clearing','clearing','USD') on conflict(account_code) do nothing;
insert into pace_v2.quality_score_config(config_name,baseline_score,rolling_window_days,half_life_days,nps_promoter_effect,nps_passive_effect,nps_detractor_effect,rating_5_effect,rating_4_effect,rating_3_effect,rating_2_effect,rating_1_effect,min_score,max_score)
values('default',50,365,180,1,0,-1,1,0.5,0,-0.5,-1,0,100) on conflict(config_name) do nothing;
insert into pace_v2.quality_configuration(config_key,operator_rating_weight,captain_rating_weight,evidence_decay_half_life_days)
values('journey_feedback',0.6,0.4,180) on conflict(config_key) do nothing;
set constraints all immediate;
set constraints all deferred;
create or replace function pg_temp.complete_fixture() returns void language plpgsql as
$$ declare n integer; begin
  for n in 8..9 loop
    perform set_config('request.jwt.claim.sub',pg_temp.fid(n+94)::text,true);
    perform public.v2_captain_start_leg(pg_temp.fid(30),pg_temp.fid(n+42));
    perform public.v2_captain_end_leg(pg_temp.fid(30),'normal',null,null,pg_temp.fid(n+42));
    perform public.v2_captain_start_leg(pg_temp.fid(31),pg_temp.fid(n+42));
    perform public.v2_captain_end_leg(pg_temp.fid(31),'normal',null,null,pg_temp.fid(n+42));
  end loop;
end $$;

select pg_temp.complete_fixture();
commit;
\ir journey_feedback_quality_behavior.sql
