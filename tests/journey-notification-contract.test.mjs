import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import test from 'node:test';

const migrationsDir = new URL('../supabase/migrations/', import.meta.url);
const migrationName = readdirSync(migrationsDir).find(name => name.endsWith('_t24_journey_notifications.sql'));
const migration = migrationName ? readFileSync(new URL(`../supabase/migrations/${migrationName}`, import.meta.url), 'utf8') : '';
const schedulerRoute = readFileSync(new URL('../app/api/operations/run-scheduled/route.ts', import.meta.url), 'utf8')
  + readFileSync(new URL('../lib/scheduled-operations-handler.ts', import.meta.url), 'utf8');

test('T-24 migration exposes a protected server-derived scheduler', () => {
  assert.ok(migration, 'T-24 journey notification migration is missing');
  assert.match(migration, /create or replace function public\.v2_system_schedule_t24_journey_notifications\(p_as_of timestamptz\)/i);
  assert.match(migration, /security definer\s+set search_path\s*=\s*pace_v2,\s*public/i);
  assert.match(migration, /revoke all on function public\.v2_system_schedule_t24_journey_notifications\(timestamp with time zone\) from public,anon,authenticated/i);
  assert.match(migration, /grant execute on function public\.v2_system_schedule_t24_journey_notifications\(timestamp with time zone\) to service_role/i);
  assert.match(migration, /from pace_v2\.bookings/i);
  assert.match(migration, /join pace_v2\.booking_allocations/i);
  assert.match(migration, /join pace_v2\.confirmed_allocations/i);
  assert.match(migration, /join pace_v2\.captain_assignments/i);
  assert.doesNotMatch(migration, /p_(?:to_email|captain|vehicle|route|recipient)/i);
});

test('T-24 scheduler de-duplicates one valid queued email by booking and template', () => {
  assert.match(migration, /create unique index[\s\S]*customer_notifications[\s\S]*booking_id[\s\S]*template_code/i);
  assert.match(migration, /template_code[^\n]*journey_tomorrow|journey_tomorrow[^\n]*template_code/i);
  assert.match(migration, /on conflict \(booking_id,template_code\) where template_code='journey_tomorrow' do nothing/i);
});

test('T-24 scheduler blocks malformed reminders and records high-priority recoverable exceptions', () => {
  assert.match(migration, /t24_details_overdue/i);
  assert.match(migration, /severity[^\n]*high/i);
  assert.match(migration, /directions_url/i);
  assert.match(migration, /timezone/i);
  assert.match(migration, /email/i);
  assert.match(migration, /resolved_at=now\(\)/i);
  assert.match(migration, /minutes_late/i);
  assert.match(migration, /where v_row\.to_email is not null/i);
});

test('T-24 uses the established customer_name shape and validates maps plus both captain names', () => {
  assert.match(migration, /to_jsonb\(b\)->>'customer_name'/i);
  assert.match(migration, /split_part\(/i);
  assert.match(migration, /is_valid_t24_directions_url\(v_row\.pickup_directions_url\)/i);
  assert.match(migration, /maps\[\.\]google\[\.\]/i);
  assert.match(migration, /maps\[\.\]app\[\.\]goo\[\.\]gl/i);
  assert.doesNotMatch(migration, /google\[a-z\.\]/i);
  assert.match(migration, /captain_first_name/i);
  assert.match(migration, /captain_last_name/i);
  assert.match(migration, /missing captain first name/i);
  assert.match(migration, /missing captain last name/i);
});

test('SQL behavior fixture invokes the scheduler and asserts queue, exception, recovery, and lateness outcomes', () => {
  const behavior = readFileSync(new URL('../supabase/tests/t24_journey_notifications_behavior.sql', import.meta.url), 'utf8');
  assert.match(behavior, /perform public\.v2_system_schedule_t24_journey_notifications/i);
  assert.match(behavior, /journey_tomorrow/i);
  assert.match(behavior, /t24_details_overdue/i);
  assert.match(behavior, /minutes_late/i);
  assert.match(behavior, /update pace_v2\.captains set first_name=''/i);
  assert.match(behavior, /last_name=''/i);
  assert.match(behavior, /missing captain last name was not withheld and alerted/i);
  assert.match(behavior, /v_as_of-interval '1 second'/i);
  assert.match(behavior, /T-24 queued or alerted before its due time/i);
  assert.match(behavior, /captain_vehicle_types cvt/i);
  assert.match(behavior, /captains cap on cap\.id=a\.captain_id and cap\.active and cap\.operator_id=ca\.operator_id/i);
  assert.match(behavior, /vehicle_types vt on vt\.id=v\.vehicle_type_id and vt\.active/i);
  assert.match(behavior, /pg_timezone_names tz on tz\.name=c\.timezone/i);
  assert.match(behavior, /select count\(distinct a2\.id\)/i);
  assert.match(behavior, /google\.com\.evil/i);
  assert.match(behavior, /google\.invalid/i);
  assert.match(behavior, /is distinct from 30/i);
  assert.match(behavior, /late correction did not queue a notification/i);
  assert.doesNotMatch(behavior, /Fixture behavior to exercise locally/i);
});

test('T-24 scheduler alerts paid bookings that have no compliant allocation yet', () => {
  assert.match(migration, /left join pace_v2\.confirmed_allocations ca/i);
  assert.match(migration, /confirmed vehicle allocation/i);
  assert.match(migration, /insert into pace_v2\.operational_alerts/i);
});

test('scheduled operations queues T-24 content before dispatching a bounded email batch', () => {
  assert.match(schedulerRoute, /v2_system_schedule_t24_journey_notifications/);
  assert.match(schedulerRoute, /p_as_of:\s*deps\.now\(\)/);
  assert.match(schedulerRoute, /now:\s*\(\)\s*=>\s*new Date\(\)\.toISOString\(\)/);
  assert.match(schedulerRoute, /deps\.dispatchDueCustomerEmails\(25\)/);
  assert.match(schedulerRoute, /status:\s*503/);
});
