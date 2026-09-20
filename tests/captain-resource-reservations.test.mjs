import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const migrationsDir=path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../supabase/migrations',
);
const behaviorPath=path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../supabase/tests/captain_resource_reservations_behavior.sql',
);
const endToEndPath=path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../supabase/tests/captain_resource_reservations_end_to_end.sql',
);

function reservationMigration(){
  const migrationName=fs.readdirSync(migrationsDir)
    .find(name=>name.endsWith('_captain_duty_reservations.sql'));

  assert.ok(migrationName,'captain duty reservations migration must exist');
  return fs.readFileSync(path.join(migrationsDir,migrationName),'utf8');
}

test('captain reservations are private and exclude overlapping active ranges',()=>{
  const sql=reservationMigration();

  assert.match(sql,/create table pace_v2\.captain_duty_reservations/i);
  assert.match(sql,/state text not null check\s*\(state in\s*\('provisional','held_t72','confirmed_t24','released'\)\)/i);
  assert.match(sql,/exclude using gist\s*\(captain_id with =,\s*duty_window with &&\)/i);
  assert.match(sql,/where\s*\(state in\s*\('provisional','held_t72','confirmed_t24'\)\)/i);
  assert.match(sql,/alter table pace_v2\.captain_duty_reservations enable row level security/i);
  assert.match(sql,/revoke all on pace_v2\.captain_duty_reservations from public,anon,authenticated/i);
});

test('every captain conflict uses the full duty plus thirty minutes',()=>{
  const sql=reservationMigration();

  assert.match(
    sql,
    /coalesce\(return_leg\.scheduled_arrival_ts,outbound\.scheduled_arrival_ts,[\s\S]*interval '8 hours'[\s\S]*\)\s*\+\s*interval '30 minutes'/i,
  );
});

test('paid demand uses deterministic private captain candidates and atomic reconciliation',()=>{
  const sql=reservationMigration();

  assert.match(
    sql,
    /create or replace function pace_v2\.captain_candidates_for_consideration\(\s*p_consideration_id uuid\s*\)[\s\S]*returns table\(captain_id uuid,priority integer\)/i,
  );
  assert.match(
    sql,
    /create or replace function pace_v2\.reconcile_departure_captain_reservations\([\s\S]*p_departure_id uuid,[\s\S]*p_target_state text,[\s\S]*p_source text[\s\S]*returns table\([\s\S]*outcome text,[\s\S]*reserved_count integer,[\s\S]*unreserved_consideration_ids uuid\[\]/i,
  );
  assert.match(sql,/pg_advisory_xact_lock[\s\S]*captain_id[\s\S]*order by[\s\S]*captain_id/i);
  assert.match(
    sql,
    /select null::uuid as captain_id[\s\S]*union all[\s\S]*from pace_v2\.captain_candidates_for_consideration/i,
  );
  assert.match(
    sql,
    /set constraints pace_v2\.captain_duty_reservations_no_overlap deferred[\s\S]*set constraints pace_v2\.captain_duty_reservations_no_overlap immediate/i,
  );
  assert.match(sql,/when exclusion_violation/i);
  assert.match(
    sql,
    /revoke all on function pace_v2\.captain_candidates_for_consideration\(uuid\)[\s\S]*from public,anon,authenticated,service_role/i,
  );
});

test('live offers, paid allocation and cancellation reconcile captain claims',()=>{
  const sql=reservationMigration();
  const behaviorSql=fs.readFileSync(behaviorPath,'utf8');

  assert.match(
    sql,
    /create or replace function pace_v2\.consideration_set_has_distinct_captains[\s\S]*captain_candidates_for_consideration/i,
  );
  assert.match(
    sql,
    /create or replace function pace_v2\.allocate_paid_booking[\s\S]*reconcile_departure_captain_reservations\([\s\S]*'provisional'[\s\S]*'paid-allocation-v1'/i,
  );
  assert.match(
    sql,
    /reservation_result\.outcome\s*<>\s*'reserved'[\s\S]*set status='cancelled'[\s\S]*'unavailable'::text/i,
  );
  assert.match(
    sql,
    /create or replace function pace_v2\.cancel_booking_and_request_refund[\s\S]*reconcile_departure_captain_reservations\([\s\S]*'provisional'[\s\S]*'booking-cancelled'/i,
  );
  assert.match(behaviorSql,/pace_v2\.allocate_paid_booking\(first_booking_id\)/i);
  assert.match(behaviorSql,/pace_v2\.allocate_paid_booking\(losing_booking_id\)/i);
  assert.match(behaviorSql,/only one overlapping paid vehicle demand can reserve the captain/i);
  assert.match(behaviorSql,/cancelling the final qualifying allocation releases the captain claim/i);
});

test('T-72 promotes staffable claims and records resource conflicts without operator withdrawal evidence',()=>{
  const sql=reservationMigration();
  const behaviorSql=fs.readFileSync(behaviorPath,'utf8');

  assert.match(
    sql,
    /alter table pace_v2\.vehicle_considerations[\s\S]*add column if not exists captain_resource_reason text[\s\S]*captain_conflict[\s\S]*no_eligible_captain[\s\S]*captain_inactive[\s\S]*captain_ineligible/i,
  );
  assert.match(
    sql,
    /create or replace function pace_v2\.evaluate_t72_booked_parties[\s\S]*reconcile_departure_captain_reservations\([\s\S]*'held_t72'/i,
  );
  assert.match(sql,/captain_resource_reason='captain_conflict'/i);
  assert.match(sql,/'T72_CAPTAIN_CONFLICT'/i);
  assert.match(sql,/'captain_resource_shortage:'\|\|p_departure_id::text/i);
  assert.doesNotMatch(sql,/captain_resource_reason='captain_conflict'[\s\S]{0,500}withdrawn_at/i);
  assert.doesNotMatch(sql,/captain_resource_reason='captain_conflict'[\s\S]{0,500}withdrawal_reason/i);
  assert.match(behaviorSql,/T-72 holds one distinct captain per staffable vehicle/i);
  assert.match(behaviorSql,/the T-72 operator email contains only held vehicles/i);
});

test('T-24 consumes the held captain and lifecycle terminal states release reservations',()=>{
  const sql=reservationMigration();

  assert.match(
    sql,
    /create or replace function pace_v2\.confirm_reserved_captain\(\s*p_confirmed_allocation_id uuid,\s*p_reservation_id uuid\s*\)[\s\S]*returns uuid/i,
  );
  assert.match(
    sql,
    /create or replace function pace_v2\.release_captain_reservations\(\s*p_departure_id uuid,\s*p_reason text\s*\)[\s\S]*returns integer/i,
  );
  assert.match(sql,/state='confirmed_t24'[\s\S]*captain_assignment_id=/i);
  assert.match(
    sql,
    /create or replace function pace_v2\.confirm_departure_t24[\s\S]*reconcile_departure_captain_reservations\([\s\S]*'held_t72'[\s\S]*T24_INSUFFICIENT_CAPTAINS/i,
  );
  assert.match(
    sql,
    /create or replace function pace_v2\.auto_assign_captain[\s\S]*confirm_reserved_captain/i,
  );
  assert.match(sql,/create trigger release_terminal_captain_reservations/i);
  assert.match(
    sql,
    /revoke all on function pace_v2\.confirm_reserved_captain\(uuid,uuid\)[\s\S]*release_captain_reservations\(uuid,text\)[\s\S]*from public,anon,authenticated,service_role/i,
  );
});

test('migration backfill preserves confirmed assignments and records conflicts',()=>{
  const sql=reservationMigration();

  assert.match(
    sql,
    /create or replace function pace_v2\.backfill_captain_duty_reservations\(\)/i,
  );
  assert.match(sql,/captain_reservation_backfill_conflict:/i);
  assert.match(sql,/exception when exclusion_violation/i);
  assert.match(sql,/order by active_assignment\.assigned_at,active_assignment\.id/i);
  assert.doesNotMatch(sql,/active_assignment\.created_at/i);
  assert.match(
    sql,
    /state,\s*confirmed_allocation_id,\s*captain_assignment_id[\s\S]*'confirmed_t24'/i,
  );
  assert.doesNotMatch(
    sql.match(/create or replace function pace_v2\.backfill_captain_duty_reservations\(\)[\s\S]*?\n\$\$;/i)?.[0]||'',
    /update pace_v2\.captain_assignments[\s\S]*active=false/i,
  );
  assert.match(
    sql,
    /select \* from pace_v2\.backfill_captain_duty_reservations\(\)/i,
  );
});

test('release rehearsal covers reservation, communications, day-of and feedback stages',()=>{
  const sql=fs.readFileSync(endToEndPath,'utf8');
  const behavior=fs.readFileSync(behaviorPath,'utf8');

  for(const fixture of [
    'captain_resource_reservations_behavior.sql',
    't24_journey_notifications_behavior.sql',
    'captain_duties_and_return_legs_contract.sql',
    'journey_feedback_quality_behavior.sql',
  ]){
    assert.ok(sql.includes(`\\ir ${fixture}`),`${fixture} must run in release rehearsal`);
  }
  assert.match(behavior,/captain_reservation_backfill_conflict:/i);
  assert.match(behavior,/active_assignment_count[\s\S]*'2'/i);
  assert.match(behavior,/confirmed_reservation_count[\s\S]*'1'/i);
});
