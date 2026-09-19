import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';

const url = new URL('../supabase/migrations/20260919180000_captain_eligibility_gate.sql', import.meta.url);
const sql = existsSync(url) ? readFileSync(url, 'utf8') : '';

test('active operators require at least one active captain', () => {
  assert.ok(sql, 'captain eligibility gate migration is missing');
  assert.match(sql, /assert_active_operator_has_captain/i);
  assert.match(sql, /operator requires at least one active captain/i);
  assert.match(sql, /constraint trigger[\s\S]*on pace_v2\.operators[\s\S]*deferrable initially deferred/i);
  assert.match(sql, /constraint trigger[\s\S]*on pace_v2\.captains[\s\S]*deferrable initially deferred/i);
});

test('active vehicles require an explicitly assigned eligible captain', () => {
  assert.match(sql, /assert_active_vehicle_has_eligible_captain/i);
  assert.match(sql, /vehicle requires an active eligible default captain/i);
  assert.match(sql, /vehicle_captain_preferences/i);
  assert.match(sql, /captain_vehicle_types/i);
  assert.match(sql, /constraint trigger[\s\S]*on pace_v2\.vehicles[\s\S]*deferrable initially deferred/i);
});

test('automatic captain selection uses route or vehicle assignments only', () => {
  assert.match(sql, /create or replace function pace_v2\.pick_default_captain/i);
  assert.doesNotMatch(sql, /select captain\.id,10000/i);
  assert.match(sql, /route_captain_id/i);
  assert.match(sql, /vehicle_captain_preferences/i);
});

