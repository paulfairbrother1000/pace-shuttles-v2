import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';

const migrationPath = new URL('../supabase/migrations/20260919191150_captain_pending_customer_notifications.sql', import.meta.url);
const behaviorPath = new URL('../supabase/tests/captain_pending_customer_notifications_behavior.sql', import.meta.url);

test('T-24 captain shortage queues one informative pending-captain email without weakening operational confirmation', () => {
  const sql = readFileSync(migrationPath, 'utf8');
  assert.match(sql, /create unique index[^;]+booking_id[^;]+departure_id[^;]+where template_code='journey_captain_pending'/is);
  assert.match(sql, /create or replace function public\.v2_system_schedule_t24_journey_notifications\(p_as_of timestamptz\)/i);
  assert.match(sql, /decision_reason_code='T24_INSUFFICIENT_CAPTAINS'/i);
  assert.match(sql, /join pace_v2\.booking_allocations ba[^;]+join pace_v2\.vehicle_considerations vc[^;]+join pace_v2\.vehicles v[^;]+join pace_v2\.vehicle_types vt/is);
  assert.match(sql, /'journey_captain_pending'/i);
  for (const key of ['first_name','pickup_name','destination_name','departure_date_label','departure_time_label','arrival_by_time_label','vehicle_type','vehicle_name','pickup_directions_url','wet_destination']) {
    assert.match(sql, new RegExp(`'${key}'`, 'i'));
  }
  assert.match(sql, /'captain_status','to_be_confirmed'\s*\)\s*\)\s*on conflict/i, 'notification VALUES must close after metadata');
  assert.match(sql, /on conflict \(booking_id,departure_id\) where template_code='journey_captain_pending' do nothing/i);
  assert.doesNotMatch(sql, /insert into pace_v2\.(?:captains|captain_assignments|confirmed_allocations)/i);
  assert.doesNotMatch(sql, /update pace_v2\.(?:departures|bookings)\s+set\s+status='confirmed'/i);
});

test('captain-pending notification remains independent from final journey-tomorrow confirmation', () => {
  const sql = readFileSync(migrationPath, 'utf8');
  assert.match(sql, /template_code='journey_captain_pending'/i);
  assert.match(sql, /template_code='journey_tomorrow'/i);
  assert.doesNotMatch(sql, /on conflict \(booking_id,template_code\)[^;]+journey_(?:captain_pending|tomorrow)[^;]+journey_(?:tomorrow|captain_pending)/is);
});

test('database behavior fixture covers queueing, deduplication, alert retention and final-email recovery', () => {
  assert.equal(existsSync(behaviorPath), true, 'captain-pending behavior fixture is missing');
  const fixture = readFileSync(behaviorPath, 'utf8');
  assert.match(fixture, /perform public\.v2_system_schedule_t24_journey_notifications/i);
  assert.match(fixture, /captain pending notification was not queued/i);
  assert.match(fixture, /captain pending notification duplicated/i);
  assert.match(fixture, /captain shortage alert was incorrectly resolved/i);
  assert.match(fixture, /final journey notification was suppressed by captain pending notification/i);
});
