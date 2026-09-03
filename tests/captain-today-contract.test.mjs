import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const migrationPath='supabase/migrations/20260902031500_captain_duties_and_return_legs.sql';
const fixturePath='supabase/tests/captain_duties_and_return_legs_contract.sql';

test('live departure timestamp drift is repaired before the migration references it',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const compatibilityAdd=/alter table pace_v2\.departures\s+add column if not exists actual_departure_ts timestamptz/i;
  const addMatch=compatibilityAdd.exec(sql);
  assert.ok(addMatch,'migration adds the legacy departure timestamp when the live schema lacks it');
  const nextReference=sql.slice(addMatch.index+addMatch[0].length).search(/actual_departure_ts/i);
  assert.ok(nextReference>=0,'migration exercises the compatibility column after adding it');
  assert.doesNotMatch(sql.slice(0,addMatch.index),/actual_departure_ts/i);
});

test('captain SQL fixtures satisfy the live non-null departure service contract',()=>{
  const fixture=readFileSync(fixturePath,'utf8');
  for(const row of ['v_one_way_id','v_outbound_id','v_return_id']){
    assert.match(fixture,new RegExp(`\\(${row},v_service_id,`,'i'),`${row} must reference the selected fixture service`);
  }
  assert.match(fixture,/\(\s*v_protected_return_id,v_one_way_service_id,v_reverse_route_id,/i);
  assert.doesNotMatch(fixture,/\(\s*v_(?:one_way_id|outbound_id|return_id|protected_return_id)\s*,\s*null\s*,/i);
});

test('captain lifecycle fixture seeds independent captain identities and allocation state',()=>{
  const fixture=readFileSync(fixturePath,'utf8');
  const seed=fixture.match(/insert into captain_today_fixture\([\s\S]*?\$captain_today_fixture_required\$;/i)?.[0]||'';
  assert.doesNotMatch(seed,/join lateral\([\s\S]*?from pace_v2\.captains c[\s\S]*?\) other_captain on true/i);
  assert.doesNotMatch(seed,/captain_2_candidate|other_captain_candidate/i);
  assert.doesNotMatch(seed,/\) operator_user on true/i);
  assert.doesNotMatch(seed,/\) assigned on true|\) party on true/i);
  assert.doesNotMatch(seed,/join pace_v2\.vehicles vehicle on vehicle\.operator_id=v_primary_operator_id/i);
  assert.doesNotMatch(seed,/from pace_v2\.confirmed_allocations source\b|source allocation, paid booking and second eligible operator vehicle required/i);
  assert.match(seed,/insert into auth\.users\s*\([\s\S]*?is_anonymous/i);
  assert.match(seed,/insert into pace_v2\.profiles\s*\(user_id,platform_role\)/i);
  assert.match(seed,/insert into pace_v2\.operator_memberships\s*\(user_id,operator_id,role,active\)/i);
  assert.match(seed,/insert into pace_v2\.orders\s*\([\s\S]*?payment_status/i);
  assert.match(seed,/insert into pace_v2\.bookings\s*\([\s\S]*?total_price_cents/i);
  assert.match(seed,/insert into pace_v2\.booking_allocations\s*\([\s\S]*?vehicle_consideration_id/i);
  for(const columns of seed.matchAll(/insert into pace_v2\.booking_allocations\s*\(([^)]*)\)/gi)){
    assert.match(columns[1],/\bunit_price_cents\b/i);
    assert.match(columns[1],/\bstatus\b/i);
    assert.doesNotMatch(columns[1],/(?:^|,)\s*unit_price\s*(?:,|$)/i);
  }
  assert.match(seed,/values\(fixture\.booking_id,v_primary_consideration_id,fixture\.outbound_id,1,1000,'confirmed'\)/i);
  assert.match(seed,/values\(v_second_booking_id,v_second_consideration_id,fixture\.outbound_id,1,1000,'confirmed'\)/i);
  assert.match(seed,/insert into pace_v2\.vehicle_considerations\s*\([\s\S]*?commercial_snapshot_source/i);
  assert.match(seed,/insert into pace_v2\.vehicles\s*\([\s\S]*?capacity_seats/i);
  assert.match(seed,/insert into pace_v2\.vehicle_route_offers\s+select\s+\(jsonb_populate_record/i);
  assert.match(seed,/update pace_v2\.captain_assignments\s+set active=false/i);
  assert.match(seed,/insert into pace_v2\.captains\s*\(operator_id,first_name,last_name,email,auth_user_id,active\)/i);
  assert.match(seed,/insert into pace_v2\.captain_vehicle_types\s*\(captain_id,vehicle_type_id,active\)/i);
  assert.match(seed,/insert into pace_v2\.confirmed_allocations\s*\([\s\S]*?operator_net_before_adjustments_cents/i);
  assert.match(seed,/insert into pace_v2\.captain_assignments\s*\(confirmed_allocation_id,captain_id,assignment_source,active\)/i);
  assert.match(seed,/fixture captain identity candidates required/i);
  assert.doesNotMatch(seed,/into\s+source_allocation\s*,/i,'a composite record cannot share a PL/pgSQL INTO list with scalars');
  assert.doesNotMatch(fixture,/update pace_v2\.vehicle_considerations consideration set departure_id=f\.outbound_id/i,
    'the paired clone must not move the untouched one-way allocation consideration');
  const allocationScope=fixture.match(/do \$captain_today_confirmed_allocation_scope\$[\s\S]*?\$captain_today_confirmed_allocation_scope\$;/i)?.[0]||'';
  assert.match(allocationScope,/update pace_v2\.confirmed_allocations allocation[\s\S]*set status='completed'/i);
  assert.match(allocationScope,/allocation\.id not in\(fixture\.allocation_id,fixture\.allocation_2_id\)/i);
  assert.match(allocationScope,/allocation\.departure_id=fixture\.outbound_id[\s\S]*allocation\.status='confirmed'/i);
  assert.match(allocationScope,/v_confirmed_count<>2/i);
});

test('service-day uniqueness allows one noncommercial return but rejects another commercial departure',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  assert.match(sql,/drop index if exists pace_v2\.ux_departures_service_local_date/i);
  assert.match(sql,/create unique index ux_departures_service_local_date\s+on pace_v2\.departures\s*\(\s*service_id\s*,\s*local_departure_date\s*\)\s*where is_commercial/i);
  assert.match(fixture,/v_outbound_id,v_service_id,v_route_id,[\s\S]{0,240}'2098-01-11'/i);
  assert.match(fixture,/v_return_id,v_service_id,v_route_id,[\s\S]{0,240}'2098-01-11'/i);
  assert.match(fixture,/second commercial departure on the same service day was accepted/i);
  assert.match(fixture,/v_protected_return_id,v_one_way_service_id,v_reverse_route_id,[\s\S]{0,320}v_operating_date\+15/i);
});

test('return journeys are explicitly paired without changing one-way departures',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  assert.match(sql,/create table pace_v2\.journey_pairs/i);
  assert.match(sql,/check \(leg_number in \(1,2\)\)/i);
  assert.match(sql,/unique .*outbound_departure_id/i);
  assert.match(sql,/unique .*return_departure_id/i);
  assert.match(sql,/create constraint trigger[\s\S]*deferrable initially deferred/i);
  assert.match(sql,/has_site_admin_access/i);
  assert.doesNotMatch(sql,/delete from pace_v2\.departures where journey_pair_id is null/i);
});

test('deferred pair integrity is RLS-independent and not directly executable',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const consistencyFunction=sql.match(/create or replace function pace_v2\.enforce_journey_pair_consistency\(\)[\s\S]*?\n\$\$;/i)?.[0];
  assert.ok(consistencyFunction,'consistency trigger function is present');
  assert.match(consistencyFunction,/security definer/i);
  assert.match(consistencyFunction,/set search_path=''/i);
  assert.match(sql,/alter function pace_v2\.enforce_journey_pair_consistency\(\) owner to postgres/i);
  assert.match(sql,/revoke all on function pace_v2\.enforce_journey_pair_consistency\(\) from public,anon,authenticated/i);
});

test('deferred pair integrity validates only identities touched by pairing changes',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const consistencyFunction=sql.match(/create or replace function pace_v2\.enforce_journey_pair_consistency\(\)[\s\S]*?\n\$\$;/i)?.[0];
  assert.ok(consistencyFunction,'consistency trigger function is present');
  assert.match(consistencyFunction,/v_pair_ids uuid\[\]/i);
  assert.match(consistencyFunction,/v_departure_ids uuid\[\]/i);
  assert.match(consistencyFunction,/unnest\(v_pair_ids\)/i);
  assert.match(consistencyFunction,/unnest\(v_departure_ids\)/i);
  assert.match(sql,/after insert or delete or update of journey_pair_id,leg_number on pace_v2\.departures/i);
  assert.doesNotMatch(consistencyFunction,/select jp\.outbound_departure_id as departure_id[\s\S]*union all[\s\S]*select jp\.return_departure_id/i);
});

test('one-way compatibility evidence is scoped to the departure created by the fixture',()=>{
  const sql=readFileSync(fixturePath,'utf8');
  assert.match(sql,/count\(\*\) from pace_v2\.departures where id=current_setting\('test\.captain_one_way_id'\)::uuid and journey_pair_id is null\),1,'one-way departure retained'/i);
  assert.doesNotMatch(sql,/count\(\*\) from pace_v2\.departures where journey_pair_id is null\),1,'one-way departure retained'/i);
});

test('Site Admin paired journey design save is atomic, protected and exposed through the typed client boundary',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const client=readFileSync('lib/data.ts','utf8');
  assert.match(sql,/create function pace_v2\.admin_save_paired_journey_design\(/i);
  assert.match(sql,/for update/i);
  assert.match(sql,/pace_v2\.is_site_admin\(\)/i);
  assert.match(sql,/from pace_v2\.bookings b/i);
  assert.match(sql,/from pace_v2\.confirmed_allocations ca/i);
  assert.match(sql,/delete from pace_v2\.departures where id=v_return_id/i);
  assert.match(sql,/return journey cannot be removed after bookings, allocations or operation evidence exist/i);
  assert.match(sql,/create function public\.v2_admin_save_paired_journey_design\(/i);
  assert.match(fixture,/admin_save_paired_journey_design\(/i);
  assert.match(fixture,/reverse route/i);
  assert.match(fixture,/same journey pair/i);
  assert.match(client,/export type PairedJourneyDesignInput=/i);
  assert.match(client,/v2_admin_save_paired_journey_design/i);
});

test('recurring return designs use an explicit route and materialize only non-commercial return legs',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const client=readFileSync('lib/data.ts','utf8');
  assert.match(sql,/create table pace_v2\.service_return_designs/i);
  assert.match(sql,/reverse_route_id uuid not null references pace_v2\.routes/i);
  assert.match(sql,/p_reverse_route_id uuid default null/i);
  assert.doesNotMatch(sql,/where r\.pickup_id=v_outbound_route\.destination_id/i);
  assert.match(sql,/add column is_commercial boolean not null default true/i);
  assert.match(sql,/departures_return_leg_noncommercial_check/i);
  assert.match(sql,/materialize_service_return_after_departure/i);
  assert.match(sql,/departures_materialize_service_return after insert/i);
  assert.match(sql,/bookings_reject_noncommercial_departure/i);
  assert.match(sql,/vehicle_considerations_reject_noncommercial_departure/i);
  assert.match(sql,/confirmed_allocations_reject_noncommercial_departure/i);
  assert.match(sql,/create or replace function public\.v2_public_quote[\s\S]*where d\.id=p_departure_id and d\.is_commercial/i);
  assert.match(sql,/create or replace function public\.v2_system_partner_shuttle_catalog[\s\S]*where d\.is_commercial and d\.scheduled_departure_ts>now\(\)/i);
  assert.match(sql,/create or replace view public\.v2_public_departures[\s\S]*where d\.is_commercial and d\.scheduled_departure_ts>now\(\)/i);
  assert.match(sql,/pg_advisory_xact_lock\(hashtextextended\(v_outbound_id::text,0\)\)/i);
  assert.match(sql,/return local time does not exist in the return route timezone/i);
  assert.match(fixture,/p_reverse_route_id=>v_reverse_route_id/i);
  assert.match(fixture,/protected removal accepted a booking/i);
  assert.match(fixture,/protected removal accepted an allocation/i);
  assert.match(client,/reverseRouteId:string\|null/i);
  assert.match(client,/p_reverse_route_id:input\.reverseRouteId/i);
});

test('return routes are explicit one-to-one Site Admin mappings, not same-country guesses',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const nextDate=sql.match(/create or replace function pace_v2\.next_service_operating_date[\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(sql,/create table pace_v2\.route_return_mappings/i);
  assert.match(sql,/unique \(outbound_route_id\)/i);
  assert.match(sql,/unique \(return_route_id\)/i);
  assert.match(sql,/check \(outbound_route_id<>return_route_id\)/i);
  assert.match(sql,/return route mapping requires Site Admin/i);
  assert.match(sql,/p_reverse_route_id is mapped as the service route return/i);
  assert.match(sql,/r\.is_active/i);
  assert.match(sql,/customer_availability_paused is not true/i);
  assert.match(sql,/v_outbound\.status<>\'scheduled\'[\s\S]*v_outbound\.actual_departure_ts is not null[\s\S]*v_outbound\.actual_arrival_ts is not null/i);
  assert.match(sql,/service-return-design:/i);
  assert.match(sql,/return route mapping cannot change while a service return design is enabled/i);
  assert.match(sql,/return route mapping requires active, distinct same-country routes/i);
  assert.match(sql,/select s\.id from pace_v2\.services s where s\.route_id=any\(v_route_ids\) order by s\.id for update/i);
  assert.match(sql,/v_today:=\(now\(\) at time zone v_service\.timezone\)::date/i);
  assert.match(sql,/d\.scheduled_departure_ts>now\(\)/i);
  assert.match(sql,/d\.status='scheduled'/i);
  assert.match(sql,/d\.local_departure_date>=coalesce\(s\.valid_from,\(now\(\) at time zone s\.timezone\)::date\)/i);
  assert.match(sql,/create or replace function pace_v2\.is_qualified_service_departure/i);
  assert.match(sql,/d\.route_id=s\.route_id/i);
  assert.match(sql,/pace_v2\.is_qualified_service_departure\(v_service\.id,v_outbound\.id,v_service\.departure_time\)/i);
  assert.match(sql,/select min\(d\.local_departure_date\) into v_operating_date/i);
  assert.match(sql,/for v_outbound_id in[\s\S]*pace_v2\.is_qualified_service_departure[\s\S]*order by d\.scheduled_departure_ts,d\.id/i);
  assert.match(sql,/create or replace function pace_v2\.next_service_operating_date/i);
  assert.match(sql,/foreach v_dow in array/i);
  assert.doesNotMatch(sql,/generate_series/i);
  assert.match(nextDate,/v_anchor:=coalesce\(v_service\.recurrence_anchor_date,v_service\.valid_from\)/i);
  assert.match(nextDate,/coalesce\(v_service\.recurrence_type,'weekly'\)='weekly' and v_anchor is not null/i);
  assert.doesNotMatch(nextDate,/coalesce\(v_service\.recurrence_anchor_date,v_service\.valid_from,v_today\)/i);
  assert.match(sql,/v_service\.valid_to is null or v_candidate<=v_service\.valid_to/i);
  assert.doesNotMatch(sql.match(/create function pace_v2\.admin_save_paired_journey_design[\s\S]*?end \$\$;/i)?.[0]||'',/current_date/i);
  assert.match(sql,/v2_admin_save_route_return_mapping/i);
  assert.match(fixture,/an unmapped same-country route was accepted as a return/i);
  assert.match(fixture,/mapping RPC remapped an enabled return design/i);
  assert.match(fixture,/direct mapping update remapped an enabled return design/i);
  assert.match(fixture,/No-departure recurrence service/i);
  assert.match(fixture,/idempotent mapping RPC did not retain the enabled return mapping/i);
  assert.match(fixture,/off-pattern generated departure was accepted/i);
  assert.match(fixture,/stale-route generated departure was accepted/i);
  assert.match(fixture,/Null-anchor recurrence service/i);
  assert.match(fixture,/Large-interval recurrence service/i);
  assert.match(fixture,/mapping deletion removed an enabled return design/i);
  assert.match(fixture,/inactive service or route blocked safe return design disable/i);
  assert.match(fixture,/Pacific\/Kiritimati/i);
  assert.match(fixture,/Etc\/GMT\+12/i);
  assert.match(fixture,/new outbound departure did not materialize the saved return design/i);
  assert.doesNotMatch(sql,/drop function public\.v2_admin_save_paired_journey_design\(uuid,time,boolean,time,integer\)/i);
  assert.doesNotMatch(sql,/create or replace function pace_v2\.admin_save_paired_journey_design/i);
  assert.match(sql,/revoke all on function pace_v2\.is_qualified_service_departure\(uuid,uuid,time\) from public,anon,authenticated/i);
  assert.match(sql,/revoke all on function pace_v2\.next_service_operating_date\(uuid,time\) from public,anon,authenticated/i);
  assert.match(sql,/revoke all on function pace_v2\.materialize_service_return_leg\(uuid\) from public,anon,authenticated/i);
  assert.match(fixture,/paired journey internal SECURITY DEFINER helpers are executable by an API role/i);
});

test('Site Admin can bootstrap and refresh a return-route mapping through the product boundary',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const client=readFileSync('lib/data.ts','utf8');
  const editor=readFileSync('components/admin-service-editor.tsx','utf8');
  assert.match(sql,/create (?:or replace )?function public\.v2_admin_route_return_mapping_options\(p_service_id uuid\)/i);
  assert.match(sql,/eligible_return_routes jsonb/i);
  assert.match(sql,/order by coalesce\(candidate\.route_name,candidate\.name\),candidate\.id/i);
  assert.match(client,/export type RouteReturnMappingInput=/i);
  assert.match(client,/adminSaveRouteReturnMapping=\(input:RouteReturnMappingInput\)=>rpc\('v2_admin_save_route_return_mapping'/i);
  assert.match(client,/adminLoadRouteReturnMappingOptions=\(serviceId:string\)=>rpc\('v2_admin_route_return_mapping_options'/i);
  assert.match(editor,/Save return route mapping/i);
  assert.match(editor,/disable and save the return journey before changing its route mapping/i);
});

test('return design save materializes and updates every pristine generated recurrence atomically',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const save=sql.match(/create function pace_v2\.admin_save_paired_journey_design\([\s\S]*?end \$\$;/i)?.[0]||'';
  const materialize=sql.match(/create or replace function pace_v2\.materialize_service_return_leg\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(save,/for v_outbound_id in[\s\S]*pace_v2\.is_qualified_service_departure[\s\S]*order by d\.scheduled_departure_ts,d\.id/i);
  assert.doesNotMatch(save,/order by d\.scheduled_departure_ts,d\.id limit 1/i);
  assert.match(materialize,/select \* into v_return[\s\S]*for update/i);
  assert.match(materialize,/return journey design cannot change after bookings, allocations or operation evidence exist/i);
  assert.match(materialize,/update pace_v2\.departures[\s\S]*set route_id=v_route\.id[\s\S]*scheduled_departure_ts=v_return_ts[\s\S]*where id=v_return_id/i);
  assert.match(fixture,/enable did not materialize every pre-generated recurrence date/i);
  assert.match(fixture,/repeated design save changed a journey pair or return departure identity/i);
  assert.match(fixture,/schedule edit did not update every pristine future return leg/i);
  assert.match(fixture,/protected design edit was not rejected atomically/i);
  assert.match(fixture,/protected design edit partially changed return schedules or design/i);
});

test('outbound time edits atomically reschedule every prior generated instance before changing the service schedule',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const save=sql.match(/create function pace_v2\.admin_save_paired_journey_design\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(save,/v_prior_outbound_time:=v_service\.departure_time/i);
  assert.match(save,/v_affected_outbound_ids/i);
  assert.match(save,/\(d\.scheduled_departure_ts at time zone v_service\.timezone\)::time=v_prior_outbound_time/i);
  assert.match(save,/foreach v_outbound_id in array v_affected_outbound_ids/i);
  assert.match(save,/scheduled_departure_ts=v_outbound_ts[\s\S]*scheduled_arrival_ts=v_outbound_arrival_ts[\s\S]*local_departure_date=\(v_outbound_ts at time zone v_service\.timezone\)::date[\s\S]*t72_ts=v_outbound_ts-make_interval\(hours=>coalesce\(v_outbound_route\.t72_hours,72\)\)[\s\S]*t24_ts=v_outbound_ts-make_interval\(hours=>coalesce\(v_outbound_route\.t24_hours,24\)\)/i);
  assert.match(save,/update pace_v2\.services[\s\S]*set departure_time=p_outbound_local_time[\s\S]*departure_time is distinct from p_outbound_local_time/i);
  assert.match(save,/outbound journey time cannot change after bookings, allocations or operation evidence exist/i);
  assert.match(fixture,/disabled return outbound edit did not reschedule every pristine one-way departure/i);
  assert.match(fixture,/enabled outbound edit did not retain departure, pair and return identities/i);
  assert.match(fixture,/enabled outbound edit did not synchronize every outbound and return timestamp/i);
  assert.match(fixture,/protected outbound edit was not rejected atomically/i);
  assert.match(fixture,/protected outbound edit partially changed service, departure, pair or return state/i);
});

test('commercial departure inserts join the service design lock protocol before becoming visible',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const guard=sql.match(/create or replace function pace_v2\.guard_service_departure_insert\(\)[\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(sql,/create trigger departures_guard_service_schedule before insert on pace_v2\.departures/i);
  assert.match(guard,/new\.is_commercial and new\.service_id is not null and new\.status='scheduled' and new\.scheduled_departure_ts>now\(\)/i);
  assert.match(guard,/from pace_v2\.services service where service\.id=new\.service_id for update/i);
  assert.match(guard,/pg_advisory_xact_lock\(hashtextextended\('service-return-design:'\|\|v_service\.id::text,0\)\)/i);
  assert.match(guard,/pg_advisory_xact_lock\(hashtextextended\(new\.id::text,0\)\)/i);
  assert.match(guard,/new\.route_id is distinct from v_service\.route_id/i);
  assert.match(guard,/new\.trip_timezone is distinct from v_service\.timezone/i);
  assert.match(guard,/new\.local_departure_date is distinct from \(new\.scheduled_departure_ts at time zone v_service\.timezone\)::date/i);
  assert.match(guard,/new\.scheduled_departure_ts at time zone v_service\.timezone\)::time is distinct from v_service\.departure_time/i);
  assert.match(guard,/extract\(dow from new\.local_departure_date\)::smallint<>all\(v_service\.days_of_week\)/i);
  assert.match(guard,/errcode='40001'[\s\S]*message='stale generated departure schedule; retry generation'/i);
  const serviceRowLock=guard.indexOf('where service.id=new.service_id for update');
  const designLock=guard.indexOf('service-return-design:');
  const departureLock=guard.indexOf('hashtextextended(new.id::text,0)');
  assert.ok(serviceRowLock>=0&&serviceRowLock<designLock&&designLock<departureLock,'insert guard lock order must be service row -> design advisory -> departure advisory');
  assert.ok(sql.indexOf('departures_guard_service_schedule before insert')<sql.indexOf('departures_materialize_service_return after insert'),'guard must run before the AFTER INSERT materializer');
  assert.match(fixture,/stale pre-edit generator insert was not rejected with retryable domain error/i);
  assert.match(fixture,/valid post-edit generator insert did not retain the current service schedule and materialize its return/i);
});

test('paired duties reserve captain and vehicle resources through the return arrival',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const window=sql.match(/create or replace function pace_v2\.captain_duty_resource_window\([\s\S]*?\n\$\$;/i)?.[0]||'';
  const vehicleOffers=sql.match(/create or replace function pace_v2\.get_eligible_vehicle_offers\([\s\S]*?\$eligibility\$;/i)?.[0]||'';
  const captain=sql.match(/create or replace function pace_v2\.pick_default_captain\([\s\S]*?\n\$\$;/i)?.[0]||'';
  const captainInvariant=sql.match(/create or replace function pace_v2\.assert_confirmed_allocation_has_eligible_captain\([\s\S]*?end \$\$;/i)?.[0]||'';
  const publicInventory=sql.match(/create or replace view public\.v2_public_departures as[\s\S]*?;\n\n-- Per-leg evidence/i)?.[0]||'';
  assert.match(window,/pair\.outbound_departure_id[\s\S]*pair\.return_departure_id/i);
  assert.match(window,/coalesce\(return_leg\.scheduled_arrival_ts[\s\S]*outbound\.scheduled_arrival_ts[\s\S]*interval '8 hours'/i);
  assert.match(vehicleOffers,/outbound_route_eligibility\.route_id=resource\.outbound_route_id/i);
  assert.match(vehicleOffers,/return_route_eligibility\.route_id=resource\.final_route_id/i);
  assert.match(vehicleOffers,/availability\.start_ts<resource\.scheduled_end_ts[\s\S]*availability\.end_ts>resource\.scheduled_start_ts/i);
  assert.match(vehicleOffers,/other_allocation\.vehicle_id=vehicle\.id[\s\S]*other_resource\.scheduled_start_ts<resource\.scheduled_end_ts[\s\S]*other_resource\.scheduled_end_ts>resource\.scheduled_start_ts/i);
  assert.match(captain,/other_resource\.scheduled_start_ts<target\.scheduled_end_ts[\s\S]*other_resource\.scheduled_end_ts>target\.scheduled_start_ts/i);
  assert.match(captainInvariant,/captain_duty_resource_window[\s\S]*confirmed allocation resource window conflicts/i);
  assert.match(publicInventory,/cross join lateral pace_v2\.get_eligible_vehicle_offers\(d\.id\) eligible/i);
  assert.match(fixture,/Leg 2 vehicle unavailability remained eligible/i);
  assert.match(fixture,/vehicle type unsupported on the return route remained public/i);
  assert.match(fixture,/captain overlap during Leg 2 remained eligible/i);
});

test('paired resource conflicts serialize and dependency changes revalidate allocations',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const invariant=sql.match(/create or replace function pace_v2\.assert_confirmed_allocation_has_eligible_captain\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(invariant,/confirmed-allocation-resource:/i);
  assert.match(invariant,/order by resource_key/i);
  assert.match(invariant,/pg_advisory_xact_lock\(hashtextextended\(v_resource_key,0\)\)/i);
  assert.match(sql,/create constraint trigger vehicle_availability_preserves_allocated_resources[\s\S]*on pace_v2\.vehicle_availability_exceptions[\s\S]*deferrable initially deferred/i);
  assert.match(sql,/create constraint trigger route_vehicle_type_preserves_allocated_resources[\s\S]*on pace_v2\.route_vehicle_types[\s\S]*deferrable initially deferred/i);
  assert.match(sql,/create or replace function pace_v2\.validate_vehicle_availability_change\(\)[\s\S]*assert_confirmed_allocation_has_eligible_captain/i);
  assert.match(sql,/create or replace function pace_v2\.validate_route_vehicle_type_change\(\)[\s\S]*assert_confirmed_allocation_has_eligible_captain/i);
  assert.match(fixture,/set constraints pace_v2\.vehicle_availability_preserves_allocated_resources immediate/i);
  assert.match(fixture,/set constraints pace_v2\.route_vehicle_type_preserves_allocated_resources immediate/i);
  assert.doesNotMatch(fixture,/set constraints (?:vehicle_availability|route_vehicle_type)_preserves_allocated_resources immediate/i);
  assert.match(fixture,/availability dependency mutation did not revalidate a confirmed allocation/i);
  assert.match(fixture,/route eligibility dependency mutation did not revalidate a confirmed allocation/i);
});

test('migration preflights every legacy confirmed allocation against the new resource invariant',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const preflight=sql.match(/do \$confirmed_allocation_resource_preflight\$[\s\S]*?\$confirmed_allocation_resource_preflight\$;/i)?.[0]||'';
  assert.match(preflight,/from pace_v2\.confirmed_allocations allocation[\s\S]*allocation\.status='confirmed'[\s\S]*order by allocation\.id/i);
  assert.match(preflight,/perform pace_v2\.assert_confirmed_allocation_has_eligible_captain\(v_allocation_id\)/i);
  assert.ok(sql.indexOf('create or replace function pace_v2.assert_confirmed_allocation_has_eligible_captain')<sql.indexOf('do $confirmed_allocation_resource_preflight$'));
  assert.match(fixture,/legacy conflicting confirmed allocation passed migration resource preflight/i);
});

test('first return enablement preflights every future commercial promise before pairing',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const save=sql.match(/create function pace_v2\.admin_save_paired_journey_design\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(save,/v_first_return_enable:=v_existing_design\.id is null and coalesce\(p_return_enabled,false\)/i);
  assert.match(save,/v_first_return_enable[\s\S]*d\.service_id=v_service\.id[\s\S]*d\.is_commercial[\s\S]*d\.scheduled_departure_ts>now\(\)/i);
  assert.match(save,/v_first_return_enable and v_outbound\.journey_pair_id is not null/i);
  assert.match(save,/\(v_outbound_time_changed or v_first_return_enable\)[\s\S]*quote\.expires_at>now\(\)/i);
  assert.match(save,/return journey cannot be enabled after bookings, allocations, active quotes, pairs or operation evidence exist/i);
  assert.match(fixture,/protected first return enable was not rejected atomically/i);
  assert.match(fixture,/protected first return enable changed service design or departure pairing/i);
  assert.match(fixture,/pristine first return enable did not pair every safe future departure/i);
});

test('protected return-removal fixture records canonical evidence without bypassing paired legacy guards',()=>{
  const fixture=readFileSync(fixturePath,'utf8');
  assert.match(fixture,/direct paired legacy start was accepted/i);
  assert.match(fixture,/insert into pace_v2\.confirmed_allocations\s*\([\s\S]*departure_id,vehicle_id,operator_id[\s\S]*select v_second_save\.outbound_departure_id/i);
  assert.match(fixture,/insert into pace_v2\.captain_assignments\(confirmed_allocation_id,captain_id,active\)[\s\S]*v_operation_allocation_id,v_operation_captain_id,true/i);
  assert.match(fixture,/insert into pace_v2\.captain_leg_operations\s*\(\s*confirmed_allocation_id,departure_id,captain_assignment_id,started_at\s*\)[\s\S]*v_operation_allocation_id,v_second_save\.return_departure_id,v_operation_assignment_id/i);
  assert.match(fixture,/delete from pace_v2\.captain_leg_operations[\s\S]*delete from pace_v2\.captain_assignments[\s\S]*delete from pace_v2\.confirmed_allocations/i);
  assert.doesNotMatch(fixture,/select allocation\.id,assignment\.id\s+into v_operation_allocation_id,v_operation_assignment_id/i);
  assert.doesNotMatch(fixture,/update pace_v2\.departures set actual_departure_ts=now\(\) where id=v_second_save\.return_departure_id;\s*begin\s*perform pace_v2\.admin_save_paired_journey_design/i);
});

test('journey pair identity changes require protected lifecycle authorization even for Site Admin',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const guard=sql.match(/create or replace function pace_v2\.enforce_journey_pair_has_site_admin_access\(\)[\s\S]*?\n\$\$;/i)?.[0]||'';
  assert.match(guard,/current_setting\('pace_v2\.journey_pair_mutation_authorized',true\)/i);
  assert.match(guard,/journey pairing may only change through protected lifecycle functions/i);
  assert.match(sql,/revoke insert,update,delete on table pace_v2\.journey_pairs from authenticated/i);
  assert.doesNotMatch(sql,/grant select,insert,update,delete on table pace_v2\.journey_pairs to authenticated/i);
  assert.match(sql,/set_config\('pace_v2\.journey_pair_mutation_authorized','on',true\)/i);
  assert.match(fixture,/direct Site Admin journey pair creation was accepted/i);
  assert.match(fixture,/direct coordinated journey pair rewrite was accepted/i);
  assert.match(fixture,/direct journey pair deletion was accepted/i);
});

test('captain Today projects only the signed-in captains local-country duties and grouped operational manifest',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const authenticatedScopes=[...fixture.matchAll(/set local role authenticated;([\s\S]*?)reset role;/gi)].map(match=>match[1]);
  assert.match(sql,/create table pace_v2\.captain_leg_operations/i);
  assert.match(sql,/create or replace function pace_v2\.captain_today_duties\(\)/i);
  assert.match(sql,/create or replace function pace_v2\.captain_today_manifest\(\)/i);
  assert.match(sql,/create or replace view public\.v2_captain_today_duties with \(security_barrier=true,security_invoker=true\)/i);
  assert.match(sql,/create or replace view public\.v2_captain_today_manifest with \(security_barrier=true,security_invoker=true\)/i);
  assert.match(sql,/\(duty_departure\.scheduled_departure_ts at time zone country\.timezone\)::date\s*=\s*\(now\(\) at time zone country\.timezone\)::date/i);
  assert.match(sql,/ca\.id\s+as duty_id/i);
  assert.match(sql,/pickup_1\.name\s+as pickup_name/i);
  assert.match(sql,/left join pace_v2\.departures leg_2[\s\S]*leg_2\.leg_number=2/i);
  assert.match(sql,/case[\s\S]*when leg_2\.id is null[\s\S]*duty_state/i);
  assert.match(sql,/leg_1_started_by_user_id uuid[\s\S]*leg_1_ended_by_user_id uuid[\s\S]*leg_1_notes text[\s\S]*leg_1_incident_summary text/i);
  assert.match(sql,/leg_2_started_by_user_id uuid[\s\S]*leg_2_ended_by_user_id uuid[\s\S]*leg_2_notes text[\s\S]*leg_2_incident_summary text/i);
  assert.match(sql,/group by[\s\S]*b\.id/i);
  assert.match(sql,/jsonb_agg\([\s\S]*jsonb_build_object\(\s*'first_name',[\s\S]*'last_name',[\s\S]*'age_group',[\s\S]*'notes'/i);
  const manifest=sql.match(/create or replace function pace_v2\.captain_today_manifest\(\)[\s\S]*?\n\$\$;/i)?.[0]||'';
  assert.match(manifest,/authorized_journey_conversation_unread_count\(conversation\.id,'captain'\)\s+as unread_count/i);
  assert.match(manifest,/conversation\.booking_id=b\.id[\s\S]*conversation\.confirmed_allocation_id=duty\.confirmed_allocation_id/i);
  assert.match(manifest,/left join lateral\([\s\S]*from pace_v2\.passengers lead_passenger[\s\S]*order by lead_passenger\.id[\s\S]*limit 1[\s\S]*\) lead_party on true/i);
  assert.doesNotMatch(manifest,/min\(p\.first_name\)|min\(p\.last_name\)/i);
  assert.doesNotMatch(manifest,/'email'\s*,|p\.email|'phone'\s*,|p\.phone/i);
  assert.match(fixture,/assigned captain did not see exactly one Today duty/i);
  assert.match(fixture,/customer saw a captain Today duty or manifest/i);
  assert.match(fixture,/other captain saw an assigned captain Today duty or manifest/i);
  assert.match(fixture,/operator saw a captain Today duty or manifest/i);
  assert.match(fixture,/manifest exposed customer email or phone/i);
  assert.match(fixture,/manifest fallback combined names from different passengers/i);
  for(const scope of authenticatedScopes){
    assert.doesNotMatch(scope,/(?:from|join)\s+pace_v2\.(?:captain_leg_operations|journey_conversations|journey_conversation_messages|voyage_logs|notifications)\b/i);
  }
});

test('captain leg RPCs authorize through the outbound allocation and serialize an idempotent two-leg lifecycle',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const client=readFileSync('lib/data.ts','utf8');
  const start=sql.match(/create or replace function public\.v2_captain_start_leg\([\s\S]*?end \$\$;/i)?.[0]||'';
  const end=sql.match(/create or replace function public\.v2_captain_end_leg\([\s\S]*?end \$\$;/i)?.[0]||'';
  for(const body of [start,end]){
    assert.match(body,/auth\.uid\(\)/i);
    assert.match(body,/ca\.departure_id=allocation_departure\.id/i);
    assert.match(body,/for update of ca,assignment/i);
    assert.match(body,/pace_v2\.captain_duty_action_allowed\(/i);
  }
  assert.match(start,/return existing_operation\.started_at/i);
  assert.match(start,/clock_timestamp\(\)/i);
  assert.match(end,/p_completion_state is null or p_completion_state not in \('normal','incident'\)/i);
  assert.match(end,/p_completion_state='incident'[\s\S]*nullif\(trim\(coalesce\(p_incident_summary,''\)\),''\) is null/i);
  assert.match(end,/return existing_operation\.ended_at/i);
  assert.match(end,/if target_leg\.id=final_leg\.id[\s\S]*public\.v2_captain_complete_journey/i);
  assert.match(sql,/revoke all on function public\.v2_captain_start_leg\(uuid\) from public,anon/i);
  assert.match(sql,/revoke all on function public\.v2_captain_end_leg\(uuid,text,text,text\) from public,anon/i);
  assert.match(sql,/grant execute on function public\.v2_captain_start_leg\(uuid\) to authenticated/i);
  assert.doesNotMatch(end.match(/if target_leg\.id<>final_leg\.id[\s\S]*?end if;/i)?.[0]||'',/v2_captain_complete_journey|actual_arrival_ts|settlement|feedback/i);
  assert.match(fixture,/end leg 1 before start was accepted/i);
  assert.match(fixture,/start leg 2 before leg 1 completion was accepted/i);
  assert.match(fixture,/end leg 2 before start was accepted/i);
  assert.match(fixture,/start leg 1 retry changed its timestamp/i);
  assert.match(fixture,/end leg 1 retry changed its timestamp/i);
  assert.match(fixture,/end leg 1 triggered whole-journey completion, settlement or feedback/i);
  assert.match(fixture,/end final leg retry changed its timestamp or duplicated integration/i);
  assert.match(client,/loadCaptainTodayDuties\(\)\{return select\('v2_captain_today_duties','first_scheduled_departure_ts',50\)\}/i);
  assert.match(client,/loadCaptainTodayManifest\(\)\{return select\('v2_captain_today_manifest','lead_passenger_name',500\)\}/i);
  assert.match(client,/captainStartLeg=\(departureId:string\)=>rpc\('v2_captain_start_leg',\{p_departure_id:departureId\}\)/i);
  assert.match(client,/captainEndLeg=\(departureId:string,state:'normal'\|'incident',notes:string,summary:string\)=>rpc\('v2_captain_end_leg',\{p_departure_id:departureId,p_completion_state:state,p_notes:notes,p_incident_summary:summary\}\)/i);
});

test('normal and incident completion summaries are canonical and retry consistently',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const end=sql.match(/create or replace function public\.v2_captain_end_leg\([\s\S]*?end \$\$;/i)?.[0]||'';
  const normalSummaryProbe=fixture.match(/v_first:=public\.v2_captain_end_leg\(\(select outbound_id from captain_today_fixture\),'normal','  leg one complete  ','   '\);[\s\S]*?blank normal summary was not canonicalized to null/i)?.[0]||'';
  assert.match(sql,/completion_state='normal' and incident_summary is null/i);
  assert.match(sql,/completion_state='incident' and nullif\(trim\(incident_summary\),''\) is not null/i);
  assert.match(end,/p_completion_state='normal'[\s\S]*nullif\(trim\(coalesce\(p_incident_summary,''\)\),''\) is not null[\s\S]*normal completion cannot include an incident summary/i);
  assert.match(end,/v_incident_summary:=case when p_completion_state='incident' then p_incident_summary else null end/i);
  assert.match(end,/existing_operation\.incident_summary is distinct from v_incident_summary/i);
  assert.match(end,/notes=p_notes,incident_summary=v_incident_summary/i);
  assert.match(normalSummaryProbe,/from public\.v2_captain_today_duties duty[\s\S]*duty\.leg_1_incident_summary is not null/i);
  assert.doesNotMatch(normalSummaryProbe,/pace_v2\.captain_leg_operations/i);
  assert.match(fixture,/direct normal completion with an incident summary was accepted/i);
  assert.match(fixture,/blank normal summary was not canonicalized to null/i);
  assert.match(fixture,/normal completion retry did not treat blank summary forms canonically/i);
});

test('shared journey completion waits for every confirmed allocation final leg',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const end=sql.match(/create or replace function public\.v2_captain_end_leg\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(end,/v_all_allocations_finished boolean/i);
  assert.match(end,/perform allocation\.id[\s\S]*allocation\.departure_id=v_outbound_id[\s\S]*order by allocation\.id for update/i);
  assert.match(end,/from pace_v2\.confirmed_allocations allocation[\s\S]*allocation\.departure_id=v_outbound_id[\s\S]*allocation\.status='confirmed'/i);
  assert.match(end,/operation\.confirmed_allocation_id=allocation\.id[\s\S]*operation\.departure_id=v_final_id/i);
  assert.match(end,/allocation\.status='confirmed'[\s\S]*operation\.ended_at is null/i);
  assert.match(end,/if v_all_allocations_finished then[\s\S]*public\.v2_captain_complete_journey/i);
  assert.match(end,/for v_finalization in[\s\S]*order by allocation\.id/i);
  assert.match(end,/set finalization_authorized=true[\s\S]*confirmed_allocation_id=v_finalization\.allocation_id/i);
  assert.match(end,/set_config\('request\.jwt\.claim\.sub',v_finalization\.captain_user_id::text,true\)[\s\S]*p_captain_assignment_id=>v_finalization\.assignment_id/i);
  assert.match(end,/set finalization_authorized=false[\s\S]*confirmed_allocation_id=v_finalization\.allocation_id/i);
  assert.match(fixture,/first allocation final leg triggered shared completion or feedback before every allocation finished/i);
  assert.match(fixture,/primary finalization completed voyage delta expected %, got %/i);
  assert.match(fixture,/primary finalization feedback delta expected %, got %/i);
  assert.match(fixture,/secondary finalization completed voyage delta expected %, got %/i);
  assert.match(fixture,/secondary finalization feedback delta expected %, got %/i);
  assert.match(fixture,/first allocation retry duplicated shared completion integration/i);
});

test('paired completion remains eligible for scheduled customer feedback',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const scheduler=sql.match(/create or replace function public\.v2_system_schedule_feedback_requests\([\s\S]*?\n\$schedule\$;/i)?.[0]||'';
  assert.match(scheduler,/ca\.status in\('confirmed','completed'\)/i);
  assert.doesNotMatch(scheduler,/ca\.status='confirmed'/i);
  assert.match(fixture,/v2_system_schedule_feedback_requests\(clock_timestamp\(\)\+interval '2 days',500\)/i);
  assert.match(fixture,/primary finalization feedback delta expected %, got %/i);
  assert.match(fixture,/secondary finalization feedback delta expected %, got %/i);
});

test('completed paired passengers can submit the feedback they are invited to provide',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const submit=sql.match(/create or replace function public\.v2_customer_submit_feedback\([\s\S]*?\n\$submit\$;/i)?.[0]||'';
  assert.match(submit,/v_user_id uuid:=auth\.uid\(\)/i);
  assert.match(submit,/is_active_paid_journey_booking\(p_booking_id,v_user_id\)/i);
  assert.match(submit,/ca\.status in\('confirmed','completed'\)/i);
  assert.match(submit,/count\(\*\) from pace_v2\.captain_assignments a2[\s\S]*a2\.active\)=1/i);
  assert.match(fixture,/v2_customer_submit_feedback\([\s\S]*'paired completion feedback'/i);
  assert.match(fixture,/completed paired passenger feedback was not persisted against its allocation/i);
  assert.ok(fixture.indexOf('v2_system_schedule_feedback_requests(clock_timestamp()+interval \'2 days\',500)')<fixture.indexOf('v2_customer_submit_feedback('));
});

test('shared completion fixture verifies the live departure completion contract',()=>{
  const fixture=readFileSync(fixturePath,'utf8');
  assert.match(fixture,/shared departure completed while a confirmed allocation remained/i);
  assert.match(fixture,/shared departure did not complete after the final confirmed allocation/i);
  assert.match(fixture,/shared departure completion timestamp missing after the final confirmed allocation/i);
  assert.match(fixture,/canonical finalization did not record primary allocation voyage arrival/i);
  assert.match(fixture,/canonical finalization did not record secondary allocation voyage arrival/i);
  const verificationOffset=fixture.indexOf('shared departure completed while a confirmed allocation remained');
  const verification=fixture.slice(fixture.lastIndexOf('do $$',verificationOffset),fixture.indexOf('end $$;',verificationOffset)+7);
  assert.match(verification,/confirmed_allocations[\s\S]*departure_id=f\.outbound_id[\s\S]*status='confirmed'/i);
  assert.match(verification,/if exists\([\s\S]*confirmed_allocations[\s\S]*then[\s\S]*d\.status='completed'[\s\S]*else/i);
  assert.match(verification,/d\.status is distinct from 'completed'/i);
  assert.match(verification,/d\.completed_at is null/i);
  assert.doesNotMatch(verification,/d\.actual_arrival_ts/i);
  assert.match(verification,/if not exists\([\s\S]*voyage_logs[\s\S]*actual_arrival_ts is not null/i);
});

test('shared finalization uses the current eligible assignment after completed evidence is reassigned',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const end=sql.match(/create or replace function public\.v2_captain_end_leg\([\s\S]*?end \$\$;/i)?.[0]||'';
  const finalization=end.match(/for v_finalization in[\s\S]*?end loop;/i)?.[0]||'';
  const projected=finalization.match(/select ([\s\S]*?)\s+from pace_v2\.confirmed_allocations allocation/i)?.[1]||'';
  for(const field of ['allocation_id','assignment_id','assignment_count','captain_user_id','completion_state','notes','incident_summary']){
    assert.match(projected,new RegExp(`(?:as\\s+)?${field}\\b`,'i'),`finalization row must project ${field}`);
  }
  assert.match(finalization,/join lateral\([\s\S]*from pace_v2\.captain_assignments integration_assignment[\s\S]*integration_assignment\.confirmed_allocation_id=allocation\.id[\s\S]*integration_assignment\.active[\s\S]*limit 1/i);
  assert.match(finalization,/operation\.completion_state,operation\.notes,operation\.incident_summary/i);
  assert.doesNotMatch(finalization,/assignment\.id=operation\.captain_assignment_id and assignment\.active/i);
  assert.match(finalization,/set finalization_authorized=true[\s\S]*confirmed_allocation_id=v_finalization\.allocation_id[\s\S]*departure_id=v_final_id[\s\S]*set_config\('request\.jwt\.claim\.sub',v_finalization\.captain_user_id::text,true\)[\s\S]*v2_captain_start_journey\([\s\S]*v2_captain_complete_journey\(/i);
  assert.doesNotMatch(finalization,/set legacy_start_authorized=true/i);
  assert.match(fixture,/secondary finalization completed voyage delta expected %, got %/i);
  assert.match(fixture,/reassigned allocation finalization retry duplicated legacy evidence/i);
  assert.match(fixture,/secondary finalization feedback delta expected %, got %/i);
});

test('unfinished paired duties remain actionable across local midnight and terminal duties leave Today',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const duties=sql.match(/create or replace function pace_v2\.captain_today_duties\(\)[\s\S]*?\n\$\$;/i)?.[0]||'';
  const window=sql.match(/create or replace function pace_v2\.captain_duty_action_allowed\([\s\S]*?\n\$\$;/i)?.[0]||'';
  const start=sql.match(/create or replace function public\.v2_captain_start_leg\([\s\S]*?end \$\$;/i)?.[0]||'';
  const end=sql.match(/create or replace function public\.v2_captain_end_leg\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(duties,/scheduled_departure_ts at time zone country\.timezone[\s\S]*operation_1\.started_at is not null[\s\S]*operation_2\.ended_at is null/i);
  assert.match(window,/p_outbound_departure_id<>p_final_departure_id[\s\S]*operation_1\.started_at is not null[\s\S]*operation_2\.ended_at is null/i);
  assert.match(window,/target_operation\.ended_by_user_id=auth\.uid\(\)/i);
  assert.match(start,/captain_duty_action_allowed\(v_allocation_id,target_leg\.id,v_outbound_id,v_final_id,country_timezone\)/i);
  assert.match(end,/captain_duty_action_allowed\(v_allocation_id,target_leg\.id,v_outbound_id,v_final_id,country_timezone\)/i);
  assert.match(sql,/revoke all on function pace_v2\.captain_duty_action_allowed\(uuid,uuid,uuid,uuid,text\)[\s\S]*from public,anon,authenticated/i);
  assert.match(fixture,/unfinished paired duty disappeared after local midnight/i);
  assert.match(fixture,/overnight paired Leg 2 start was rejected/i);
  assert.match(fixture,/overnight paired incident completion was rejected/i);
  assert.match(fixture,/completed overnight paired duty remained in Today/i);
  assert.match(fixture,/unrelated historical duty action was accepted/i);
});

test('started paired duty carryover expires after its bounded recovery window',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const duties=sql.match(/create or replace function pace_v2\.captain_today_duties\(\)[\s\S]*?\n\$\$;/i)?.[0]||'';
  const window=sql.match(/create or replace function pace_v2\.captain_duty_action_allowed\([\s\S]*?\n\$\$;/i)?.[0]||'';
  assert.match(sql,/create or replace function pace_v2\.captain_duty_recovery_deadline\([\s\S]*interval '24 hours'/i);
  assert.match(duties,/operation_1\.started_at is not null[\s\S]*now\(\)<=pace_v2\.captain_duty_recovery_deadline/i);
  assert.match(window,/operation_1\.started_at is not null[\s\S]*now\(\)<=pace_v2\.captain_duty_recovery_deadline/i);
  assert.match(sql,/captain duty recovery window expired; escalate to Site Admin/i);
  assert.match(fixture,/stale started paired duty remained in Today/i);
  assert.match(fixture,/stale started paired duty action did not require Site Admin escalation/i);
});

test('completed exact End replay remains actor-gated and idempotent after the recovery ceiling',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const window=sql.match(/create or replace function pace_v2\.captain_duty_action_allowed\([\s\S]*?\n\$\$;/i)?.[0]||'';
  const start=sql.match(/create or replace function public\.v2_captain_start_leg\([\s\S]*?end \$\$;/i)?.[0]||'';
  const end=sql.match(/create or replace function public\.v2_captain_end_leg\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(window,/target_operation\.ended_at is not null\s+and target_operation\.ended_by_user_id=auth\.uid\(\)\s+\),false\)/i);
  assert.match(start,/ca\.status in\('confirmed','completed'\)/i);
  assert.match(end,/ca\.status in\('confirmed','completed'\)/i);
  assert.match(end,/existing_operation\.ended_by_user_id is distinct from auth\.uid\(\)[\s\S]*captain assignment required/i);
  assert.match(fixture,/cross-deadline exact completion retry changed evidence or failed/i);
  assert.match(fixture,/completed final-leg replay by another captain was accepted/i);
  assert.match(fixture,/set_config\('request\.jwt\.claim\.sub',\s*\(select captain_user_id::text from captain_today_fixture\),true\)[\s\S]*v_retry:=public\.v2_captain_end_leg\(\(select return_id/i);
});

test('paired duties cannot bypass audited start through the legacy journey RPC',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const guard=sql.match(/create or replace function pace_v2\.prevent_paired_legacy_completion\(\)[\s\S]*?end \$\$;/i)?.[0]||'';
  const start=sql.match(/create or replace function public\.v2_captain_start_leg\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(sql,/legacy_start_authorized boolean not null default false/i);
  assert.match(guard,/new\.actual_departure_ts is distinct from old\.actual_departure_ts[\s\S]*legacy_start_authorized[\s\S]*finalization_authorized/i);
  assert.match(sql,/before insert or update of actual_departure_ts,actual_arrival_ts on pace_v2\.voyage_logs/i);
  assert.match(sql,/before update of journey_pair_id,leg_number,actual_departure_ts,actual_arrival_ts on pace_v2\.departures/i);
  assert.match(start,/set legacy_start_authorized=true[\s\S]*v2_captain_start_journey[\s\S]*set legacy_start_authorized=false/i);
  assert.match(fixture,/legacy start bypass opened a paired duty/i);
});

test('paired messaging closes from Leg 2 completion and never from the outbound-only window',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const close=sql.match(/create or replace function pace_v2\.journey_message_closes_at\([\s\S]*?\n\$\$;/i)?.[0]||'';
  const oneWayProbe=fixture.match(/do \$one_way_message_close_contract\$[\s\S]*?\$one_way_message_close_contract\$;/i)?.[0]||'';
  assert.match(close,/return_leg\.scheduled_arrival_ts[\s\S]*journey_pairs pair/i);
  assert.match(close,/captain_leg_operations final_operation[\s\S]*final_operation\.confirmed_allocation_id=allocation\.id/i);
  assert.match(close,/greatest\(return_leg\.scheduled_arrival_ts\+interval '12 hours',now\(\)\+interval '4 hours'\)/i);
  assert.match(close,/final_operation\.ended_at\+interval '4 hours'/i);
  assert.match(close,/outbound\.actual_arrival_ts\+interval '4 hours'[\s\S]*outbound\.scheduled_arrival_ts\+interval '12 hours'/i);
  assert.match(oneWayProbe,/insert into pace_v2\.departures[\s\S]*is_commercial[\s\S]*'cancelled',true[\s\S]*insert into pace_v2\.confirmed_allocations/i);
  assert.doesNotMatch(oneWayProbe,/where allocation\.status='confirmed' and departure\.journey_pair_id is null/i);
  assert.doesNotMatch(oneWayProbe,/journey_pair_mutation_authorized|delete from pace_v2\.journey_pairs|set journey_pair_id=null/i);
  assert.match(fixture,/paired messaging closed before delayed Leg 2 completion/i);
  assert.match(fixture,/paired messaging did not retain the post-completion window/i);
  assert.match(fixture,/one-way messaging close behavior changed/i);
});

test('an incident-ended leg is terminal and requires Site Admin escalation',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const start=sql.match(/create or replace function public\.v2_captain_start_leg\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(start,/previous_operation\.completion_state='incident'/i);
  assert.match(start,/incident-ended duty cannot start another leg; escalate to Site Admin/i);
  assert.match(fixture,/incident-ended Leg 1 allowed Leg 2 to start/i);
  assert.match(fixture,/v2_captain_end_leg\(\s*\(select outbound_id from captain_today_fixture\),'normal','terminal incident',null\s*\)[\s\S]*incident completion was rewritten as normal/i);
  assert.match(fixture,/incident completion was rewritten as normal/i);
});

test('captain leg start and end actors are recorded and immutable',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const start=sql.match(/create or replace function public\.v2_captain_start_leg\([\s\S]*?end \$\$;/i)?.[0]||'';
  const end=sql.match(/create or replace function public\.v2_captain_end_leg\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(sql,/started_by_user_id uuid references auth\.users\(id\)/i);
  assert.match(sql,/ended_by_user_id uuid references auth\.users\(id\)/i);
  assert.match(start,/started_by_user_id=auth\.uid\(\)/i);
  assert.match(end,/ended_by_user_id=auth\.uid\(\)/i);
  assert.match(sql,/create or replace function pace_v2\.protect_captain_leg_operation_actors\(\)/i);
  assert.match(sql,/captain leg start actor is immutable/i);
  assert.match(sql,/captain leg end actor is immutable/i);
  assert.match(sql,/captain leg completion evidence is immutable/i);
  assert.match(sql,/before update of started_at,started_by_user_id,ended_at,ended_by_user_id,completion_state,notes,incident_summary on pace_v2\.captain_leg_operations/i);
  assert.match(fixture,/captain leg start actor was not attributed to the authenticated captain/i);
  assert.match(fixture,/captain leg end actor was not attributed to the authenticated captain/i);
  assert.match(fixture,/captain leg start actor rewrite was accepted/i);
  assert.match(fixture,/captain leg end actor rewrite was accepted/i);
  assert.match(fixture,/captain leg completion evidence rewrite was accepted/i);
});

test('an assigned captain can atomically start a private thread for a manifest party',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const client=readFileSync('lib/data.ts','utf8');
  const open=sql.match(/create or replace function public\.v2_captain_open_party_conversation\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(open,/auth\.uid\(\)/i);
  assert.match(open,/p_request_id uuid/i);
  assert.match(open,/ca\.id=p_confirmed_allocation_id[\s\S]*b\.id=p_booking_id/i);
  assert.match(open,/c\.auth_user_id=v_user_id/i);
  assert.match(open,/pace_v2\.is_active_paid_journey_booking\(b\.id,null\)/i);
  assert.match(open,/pace_v2\.is_journey_message_window_open\(p_confirmed_allocation_id,now\(\)\)/i);
  assert.match(open,/on conflict\(booking_id,confirmed_allocation_id\) do update/i);
  assert.match(open,/insert into pace_v2\.journey_conversation_messages/i);
  assert.match(open,/insert into pace_v2\.captain_private_message_requests/i);
  assert.match(open,/on conflict\(request_id\) do nothing/i);
  assert.match(open,/private message request belongs to another captain, allocation, booking or payload/i);
  assert.ok(open.indexOf('select * into v_existing_request')<open.indexOf('is_journey_message_window_open'), 'completed request replay must be checked before the live messaging window');
  assert.match(sql,/revoke all on function public\.v2_captain_open_party_conversation\(uuid,uuid,text,text,uuid\) from public,anon,authenticated/i);
  assert.match(sql,/grant execute on function public\.v2_captain_open_party_conversation\(uuid,uuid,text,text,uuid\) to authenticated/i);
  assert.match(client,/captainOpenPartyConversation=async\(allocationId:string,bookingId:string,message:string,category:string,requestId\?:string\)/i);
  assert.match(client,/p_request_id:requestId/i);
  assert.match(fixture,/captain could not initiate a private thread without an existing conversation/i);
  assert.match(fixture,/unassigned captain initiated a private party thread/i);
  assert.match(fixture,/private thread retry duplicated the first message/i);
  assert.match(fixture,/completed private thread retry was blocked after the messaging window closed/i);
  assert.match(fixture,/another caller replayed a completed private thread request after window close/i);
  assert.match(fixture,/stale private thread request was accepted for changed payload/i);
});

test('paired duties cannot bypass final-leg completion through the legacy captain RPC',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  assert.match(sql,/create or replace function pace_v2\.prevent_paired_legacy_completion\(\)/i);
  assert.match(sql,/before insert or update of actual_departure_ts,actual_arrival_ts on pace_v2\.voyage_logs/i);
  assert.match(sql,/before update of journey_pair_id,leg_number,actual_departure_ts,actual_arrival_ts on pace_v2\.departures/i);
  assert.match(sql,/finalization_authorized/i);
  assert.match(sql,/paired duty must be completed with v2_captain_end_leg/i);
  assert.match(fixture,/legacy completion bypass closed a paired duty before leg 2/i);
  assert.match(fixture,/legacy completion bypass changed settlement or feedback evidence/i);
});

test('captain evidence and duty identity are allocation-specific and ambiguous actions fail closed',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  assert.match(sql,/primary key \(confirmed_allocation_id,departure_id\)/i);
  assert.match(sql,/ca\.id as duty_id/i);
  assert.match(sql,/operation_1\.confirmed_allocation_id=ca\.id/i);
  assert.match(sql,/operation_2\.confirmed_allocation_id=ca\.id/i);
  assert.match(sql,/count\(\*\)[\s\S]*captain duty is ambiguous for departure/i);
  assert.match(fixture,/two allocations on one departure shared leg evidence/i);
  assert.match(fixture,/captain manifest crossed confirmed allocations/i);
  assert.match(fixture,/ambiguous captain departure action was accepted/i);
});

test('one-way duties adopt legacy timestamps while paired incident and retry evidence remains explicit',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const oneWaySeed=fixture.match(/do \$captain_one_way_self_seed\$[\s\S]*?\$captain_one_way_self_seed\$;/i)?.[0]||'';
  assert.match(sql,/coalesce\(operation_1\.started_at,legacy_actual_departure_ts\)/i);
  assert.match(sql,/coalesce\(operation_1\.ended_at,legacy_actual_arrival_ts\)/i);
  assert.match(sql,/leg_1_completion_state text/i);
  assert.match(sql,/leg_2_completion_state text/i);
  assert.match(sql,/when [\s\S]*completion_state='incident' then 'incident'/i);
  const end=sql.match(/create or replace function public\.v2_captain_end_leg\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(end,/notes=p_notes,incident_summary=v_incident_summary/i);
  assert.match(end,/existing_operation\.notes is distinct from p_notes/i);
  assert.match(end,/existing_operation\.incident_summary is distinct from v_incident_summary/i);
  assert.match(fixture,/legacy one-way in-progress timestamp was not adopted/i);
  assert.match(fixture,/completed one-way duty remained in Today/i);
  assert.match(oneWaySeed,/v_departure_ts-make_interval\(hours=>coalesce\(route\.t24_hours,24\)\),\s*'confirmed',true/i);
  assert.match(fixture,/one-way compatibility fixture expected exactly one confirmed allocation/i);
  assert.match(fixture,/one-way compatibility fixture departure was not confirmed before completion/i);
  assert.match(fixture,/legacy one-way canonical completion did not set departure completed status/i);
  assert.match(fixture,/legacy one-way canonical completion did not set departure completed timestamp/i);
  assert.match(fixture,/legacy one-way canonical completion did not persist departure arrival/i);
  assert.match(fixture,/legacy one-way canonical completion did not set allocation completed/i);
  assert.match(fixture,/legacy one-way canonical completion did not persist voyage arrival/i);
  assert.match(fixture,/legacy one-way compatibility did not persist completed operation evidence/i);
  assert.doesNotMatch(fixture,/legacy one-way completed duty state was not preserved/i);
  assert.match(fixture,/leg 2 start retry changed its timestamp/i);
  assert.match(fixture,/incident completion was not projected/i);
  assert.match(oneWaySeed,/generate_series\(0,4095\)/i);
  assert.match(oneWaySeed,/not exists\(\s*select 1 from pace_v2\.departures existing[\s\S]*existing\.service_id=service\.id[\s\S]*existing\.local_departure_date=[\s\S]*existing\.is_commercial/i);
  assert.ok(oneWaySeed.indexOf('generate_series(0,4095)')<oneWaySeed.indexOf('insert into pace_v2.departures'));
});

test('Today timezone failures are row-isolated and action helpers remain protected',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  assert.match(sql,/pg_catalog\.pg_timezone_names/i);
  assert.match(sql,/captain duty timezone is invalid/i);
  assert.match(sql,/revoke all on function pace_v2\.prevent_paired_legacy_completion\(\) from public,anon,authenticated/i);
  assert.match(fixture,/invalid country timezone broke the captain Today projection/i);
  assert.match(fixture,/invalid country timezone action did not return the domain error/i);
  assert.match(fixture,/secondary finalization completed voyage delta expected %, got %/i);
});

test('paired completion guards survive pairing metadata transitions while one-way writes remain compatible',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const guard=sql.match(/create or replace function pace_v2\.prevent_paired_legacy_completion\(\)[\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(guard,/old\.journey_pair_id is not null[\s\S]*new\.journey_pair_id is not null/i);
  assert.match(guard,/old\.leg_number is not null[\s\S]*new\.leg_number is not null/i);
  assert.match(guard,/coalesce\(new\.journey_pair_id,old\.journey_pair_id\)/i);
  assert.match(sql,/before update of journey_pair_id,leg_number,actual_departure_ts,actual_arrival_ts on pace_v2\.departures/i);
  assert.match(fixture,/direct paired departure completion was accepted/i);
  assert.match(fixture,/direct paired voyage completion was accepted/i);
  assert.match(fixture,/combined unpair and completion was accepted/i);
  assert.match(fixture,/ordinary one-way direct completion was rejected/i);
  assert.match(fixture,/ordinary one-way legacy completion was rejected/i);
  assert.match(fixture,/shared departure completed while a confirmed allocation remained/i);
});

test('captain actions lock and revalidate a stable pair identity before evidence writes',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const helper=sql.match(/create or replace function pace_v2\.lock_captain_duty_identity\([\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(helper,/service-return-design:/i);
  assert.match(helper,/pg_advisory_xact_lock\(hashtextextended\(v_outbound_id::text,0\)\)/i);
  assert.match(helper,/from pace_v2\.departures[\s\S]*for update[\s\S]*from pace_v2\.journey_pairs[\s\S]*for update/i);
  assert.match(helper,/journey pair identity changed; retry action/i);
  const serviceRowLock=helper.indexOf("where service.id=v_initial.service_id for update");
  const serviceLock=helper.indexOf("service-return-design:");
  const departureLock=helper.indexOf("hashtextextended(v_outbound_id::text,0)");
  const outboundRowLock=helper.indexOf("where departure.id=v_outbound_id for update");
  const pairRowLock=helper.indexOf("where pair.id=v_initial.journey_pair_id for update");
  const finalRowLock=helper.indexOf("where departure.id=v_final_id for update");
  assert.ok(serviceRowLock>=0&&serviceRowLock<serviceLock&&serviceLock<departureLock&&departureLock<outboundRowLock&&outboundRowLock<pairRowLock&&pairRowLock<finalRowLock);
  for(const name of ['v2_captain_start_leg','v2_captain_end_leg']){
    const body=sql.match(new RegExp(`create or replace function public\\.${name}\\([\\s\\S]*?end \\$\\$;`,'i'))?.[0]||'';
    assert.match(body,/pace_v2\.lock_captain_duty_identity\(p_departure_id\)/i);
    assert.match(body,/target_leg\.id is distinct from v_locked_identity\.target_departure_id/i);
  }
  assert.match(sql,/revoke all on function pace_v2\.lock_captain_duty_identity\(uuid\) from public,anon,authenticated/i);
  assert.match(fixture,/captain action accepted a changed pair identity/i);
  assert.match(fixture,/captain evidence used an unvalidated duty identity/i);
});

test('paired completion evidence is immutable after finalization except for exact no-op writes',()=>{
  const sql=readFileSync(migrationPath,'utf8');
  const fixture=readFileSync(fixturePath,'utf8');
  const guard=sql.match(/create or replace function pace_v2\.prevent_paired_legacy_completion\(\)[\s\S]*?end \$\$;/i)?.[0]||'';
  assert.match(guard,/tg_op='UPDATE' and new\.actual_arrival_ts is not distinct from old\.actual_arrival_ts[\s\S]*return new/i);
  assert.doesNotMatch(guard,/if new\.actual_arrival_ts is null[\s\S]{0,80}return new/i);
  assert.match(fixture,/paired departure completion clearing was accepted/i);
  assert.match(fixture,/paired departure completion change was accepted/i);
  assert.match(fixture,/paired voyage completion clearing was accepted/i);
  assert.match(fixture,/paired voyage completion change was accepted/i);
  assert.match(fixture,/exact paired completion no-op write was rejected/i);
  assert.match(fixture,/legacy_departure_arrival_before_retry timestamptz/i);
  assert.match(fixture,/legacy_voyage_arrival_before_retry timestamptz/i);
  assert.match(fixture,/departure\.actual_arrival_ts is distinct from f\.legacy_departure_arrival_before_retry/i);
  assert.match(fixture,/voyage\.actual_arrival_ts is distinct from f\.legacy_voyage_arrival_before_retry/i);
  assert.match(fixture,/completion retry mutated legacy evidence/i);
});
