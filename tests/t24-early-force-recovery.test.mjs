import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';

const migrationUrl = new URL(
  '../supabase/migrations/20260919170000_recover_early_forced_t24_runs.sql',
  import.meta.url,
);
const migration = existsSync(migrationUrl) ? readFileSync(migrationUrl, 'utf8') : '';
const reservationMigrationUrl = new URL(
  '../supabase/migrations/20260919230203_captain_duty_reservations.sql',
  import.meta.url,
);
const reservationMigration = existsSync(reservationMigrationUrl)
  ? readFileSync(reservationMigrationUrl,'utf8')
  : '';

test('a genuine T-24 run reclaims an early forced scheduler record', () => {
  assert.ok(migration, 'early forced T-24 recovery migration is missing');
  assert.match(migration, /create or replace function pace_v2\.process_departure_t24/i);
  assert.match(migration, /on conflict \(job_name,departure_id,phase,scheduled_for\)/i);
  assert.match(migration, /do update[\s\S]*started_at\s*=\s*now\(\)/i);
  assert.match(migration, /outcome\s*=\s*'\{\}'::jsonb/i);
  assert.match(migration, /scheduled_job_runs\.started_at\s*<\s*(?:pace_v2\.)?scheduled_job_runs\.scheduled_for/i);
  assert.match(migration, /now\(\)\s*>=\s*(?:pace_v2\.)?scheduled_job_runs\.scheduled_for/i);
  assert.match(migration, /returning id into jr/i);
});

test('recovery remains idempotent after an on-time run', () => {
  assert.match(migration, /if jr is null then[\s\S]*already_processed/i);
  assert.match(migration, /scheduled_job_runs\.started_at\s*<\s*(?:pace_v2\.)?scheduled_job_runs\.scheduled_for/i);
});

test('T-24 stops safely for manual review when confirmed boats outnumber eligible captains', () => {
  assert.match(migration, /T24_INSUFFICIENT_CAPTAINS/i);
  assert.match(migration, /captain_vehicle_types/i);
  assert.match(migration, /status='at_risk'/i);
  assert.match(migration, /T24_CUSTOMER_ACTION_REQUIRED/i);
});

test('T-24 rematches held captains before creating confirmed allocations',()=>{
  assert.ok(reservationMigration,'captain reservation migration is missing');
  const confirm=reservationMigration.match(
    /create or replace function pace_v2\.confirm_departure_t24[\s\S]*?\n\$\$;/i,
  )?.[0]||'';
  assert.match(confirm,/reconcile_departure_captain_reservations/i);
  assert.match(confirm,/T24_INSUFFICIENT_CAPTAINS/i);
  assert.match(confirm,/confirm_departure_t24_commercial/i);
});
