import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';

const migrationUrl = new URL(
  '../supabase/migrations/20260915050000_fix_partner_catalogue_and_scheduler_timeouts.sql',
  import.meta.url,
);
const migration = existsSync(migrationUrl) ? readFileSync(migrationUrl, 'utf8') : '';

function functionBody(name, marker) {
  const match = migration.match(
    new RegExp(`create or replace function public\\.${name}\\([\\s\\S]*?\\$${marker}\\$;`, 'i'),
  );
  return match?.[0] ?? '';
}

test('partner catalogue scopes a set-based eligibility query before reading future departures', () => {
  assert.equal(existsSync(migrationUrl), true, 'the forward production repair migration must exist');
  const catalogue = functionBody('v2_system_partner_shuttle_catalog', 'partner_catalogue');
  assert.notEqual(catalogue, '', 'the migration must replace the partner catalogue function');
  assert.match(catalogue, /r\.country_id\s*=\s*v_partner\.country_id/i);
  assert.match(catalogue, /d\.is_commercial/i);
  for (const table of [
    'vehicle_route_offers',
    'vehicles',
    'operators',
    'operator_vehicle_types',
    'route_vehicle_types',
    'vehicle_availability_exceptions',
  ]) {
    assert.match(catalogue, new RegExp(`pace_v2\\.${table}`, 'i'));
  }
  assert.doesNotMatch(catalogue, /get_eligible_vehicle_offers\s*\(\s*d\.id\s*\)/i);
});

test('hourly scheduler generates at most one missing horizon date before operational phases', () => {
  assert.equal(existsSync(migrationUrl), true, 'the forward production repair migration must exist');
  const scheduler = functionBody('v2_system_run_scheduled_operations', 'scheduled_operations');
  assert.notEqual(scheduler, '', 'the migration must replace the scheduled operations function');
  assert.match(scheduler, /v_generation_date\s+date/i);
  assert.match(scheduler, /generate_series\s*\(\s*current_date\s*\+\s*340\s*,\s*current_date\s*\+\s*380/i);
  assert.match(
    scheduler,
    /generate_departures\s*\(\s*v_generation_date\s*,\s*v_generation_date\s*\)/i,
  );
  assert.doesNotMatch(
    scheduler,
    /generate_departures\s*\(\s*\(\s*current_date\s*\+\s*340\s*\)[\s\S]*current_date\s*\+\s*380/i,
  );
  assert.match(scheduler, /process_departure_t72/i);
  assert.match(scheduler, /process_departure_t24/i);
});
