import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
import test from 'node:test';

const migrationsDir=new URL('../supabase/migrations/',import.meta.url);
const migrationName=readdirSync(migrationsDir).find(name=>name.endsWith('_default_return_journeys.sql'));
const continuationNames=readdirSync(migrationsDir)
  .filter(name=>/_continue_default_return_backfill_[1-7]\.sql$/.test(name))
  .sort();

test('all active services receive deterministic same-duration return designs',()=>{
  assert.ok(migrationName,'default return journey migration is missing');
  const sql=readFileSync(new URL(migrationName,migrationsDir),'utf8');
  assert.match(sql,/create or replace function pace_v2\.default_return_local_time\(/i);
  assert.match(sql,/date_trunc\(\s*'hour'/i);
  assert.match(sql,/make_interval\(mins\s*=>\s*p_duration_minutes\s*\+\s*180\)/i);
  assert.match(sql,/insert into pace_v2\.service_return_designs/i);
  assert.match(sql,/return_duration_minutes[\s\S]*approx_duration_mins/i);
  assert.match(sql,/pace-v2:return-route:/i);
  assert.match(sql,/insert into pace_v2\.route_vehicle_types/i);
});

test('existing protected future departures are paired and captain windows extended',()=>{
  assert.ok(migrationName,'default return journey migration is missing');
  const sql=readFileSync(new URL(migrationName,migrationsDir),'utf8');
  assert.match(sql,/status not in\s*\(\s*'cancelled'\s*,\s*'completed'\s*\)/i);
  assert.match(sql,/insert into pace_v2\.journey_pairs/i);
  assert.match(sql,/journey_pair_mutation_authorized/i);
  assert.match(sql,/captain_duty_resource_window/i);
  assert.match(sql,/update pace_v2\.captain_duty_reservations/i);
});

test('the historical inventory backfill is completed in bounded migration transactions',()=>{
  assert.equal(continuationNames.length,7);
  for(const name of continuationNames){
    const sql=readFileSync(new URL(name,migrationsDir),'utf8');
    assert.match(sql,/pace_v2\.backfill_default_return_journeys\(250\)/i);
  }
});

test('T-24 customer reminders fail closed without a return pairing',()=>{
  assert.ok(migrationName,'default return journey migration is missing');
  const sql=readFileSync(new URL(migrationName,migrationsDir),'utf8');
  const guard=sql.match(/create or replace function pace_v2\.require_return_pairing_for_t24_notification\(\)[\s\S]*?\n\$\$;/i)?.[0]||'';
  assert.match(guard,/template_code='journey_tomorrow'/i);
  assert.match(guard,/not exists[\s\S]*journey_pairs[\s\S]*return null/i);
  assert.match(guard,/return journey pairing/i);
  assert.match(sql,/notifications_require_return_pairing_for_t24/i);
  assert.match(sql,/dispatch_hold[\s\S]*missing_authoritative_return_configuration/i);
  assert.match(sql,/v2_system_schedule_t24_journey_notifications\(now\(\)\)/i);
});
