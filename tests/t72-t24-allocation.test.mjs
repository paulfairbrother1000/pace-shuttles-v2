import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const migrationUrl = new URL(
  '../supabase/migrations/20260916204749_t72_rebalance_and_t24_fleet_consolidation.sql',
  import.meta.url,
);
const behaviorUrl = new URL(
  '../supabase/tests/t72_t24_allocation_behavior.sql',
  import.meta.url,
);

test('allocation windows delay discounts until T-72 and keep discounted parties vehicle-bound', () => {
  const sql = fs.readFileSync(migrationUrl, 'utf8');

  assert.match(sql, /d\.t72_ts\s*>\s*now\(\)/i);
  assert.match(sql, /PRE_T72_NEXT_MINIMUM/i);
  assert.match(sql, /POST_T72_DISCOUNT_COMPETITION/i);
  assert.match(sql, /discount_applied[\s\S]*locked_consideration_id/i);
  assert.match(sql, /revoke all on function pace_v2\.evaluate_t72_booked_parties/i);
  assert.match(sql, /revoke all on function pace_v2\.process_departure_t24/i);
});

test('T-72 rebalances whole parties and requires minimum seats for every survivor', () => {
  const sql = fs.readFileSync(migrationUrl, 'utf8');

  assert.match(sql, /plan_t72_whole_party_allocations/i);
  assert.match(sql, /ba\.seats\s*=\s*b\.seats/i);
  assert.match(sql, /assigned_seats\s*>=\s*vc\.normal_min_seats/i);
  assert.match(sql, /T72_WHOLE_PARTY_REBALANCE/i);
  assert.match(sql, /power\(vehicle_count::numeric,booking_count::numeric\)<=100000/i);
  assert.match(sql, /planner limit exceeded[\s\S]*manual review required/i);
  assert.match(sql, /T72_NO_FEASIBLE_WHOLE_PARTY_PLAN/i);
  assert.match(sql, /No complete allocation can keep every booking party whole/i);
  assert.match(sql, /assigned_revenue_cents<pace_v2\.required_consideration_revenue_cents/i);
});

test('T-24 consolidates only within an operator and records the approved reason', () => {
  const sql = fs.readFileSync(migrationUrl, 'utf8');

  assert.match(sql, /consolidate_operator_fleet_t24/i);
  assert.match(sql, /operator_id\s*=\s*p_operator_id/i);
  assert.match(sql, /Not required — operator fleet consolidated at T-24/i);
  assert.match(sql, /consolidated_party_count\s*:=\s*pace_v2\.consolidate_departure_fleet_t24/i);
  assert.match(sql, /T24_INCOMPLETE_BOOKING_COVERAGE/i);
  assert.match(sql, /at_risk_manual_review/i);
  assert.match(sql, /revoke all on function pace_v2\.confirm_departure_t24/i);
  assert.match(sql, /revoke all on function pace_v2\.get_live_party_offer_candidates/i);
});

test(
  'transactional database behavior fixture executes when a test database is configured',
  { skip: !process.env.PACE_TEST_DATABASE_URL },
  () => {
    const migration = fs.readFileSync(migrationUrl, 'utf8');
    const behavior = fs
      .readFileSync(behaviorUrl, 'utf8')
      .replace(/^\s*(begin|rollback);\s*$/gim, '');
    const sql = `begin;\n${migration}\n${behavior}\nrollback;\n`;
    const result = spawnSync(
      'psql',
      ['-X', '-v', 'ON_ERROR_STOP=1', process.env.PACE_TEST_DATABASE_URL],
      { input: sql, encoding: 'utf8' },
    );

    assert.equal(
      result.status,
      0,
      `transactional allocation behavior failed:\n${result.stderr || result.stdout}`,
    );
  },
);
