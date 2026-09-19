import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const migration = readFileSync(
  new URL('../supabase/migrations/20260919185424_enforce_distinct_captain_capacity.sql', import.meta.url),
  'utf8',
);

test('fleet capacity requires a distinct eligible captain for every simultaneous vehicle', () => {
  assert.match(migration, /create or replace function pace_v2\.consideration_set_has_distinct_captains/i);
  assert.match(migration, /captain\.(?:id|captain_id)\s*<>\s*all\s*\(matching\.captain_ids\)/i);
  assert.match(migration, /array_length\(matching\.captain_ids,\s*1\).*vehicle_count/is);
});

test('pre-T-72 offers cannot open a vehicle that would exceed captain coverage', () => {
  const offerFunction = migration.match(
    /create or replace function pace_v2\.get_live_party_offer_candidates[\s\S]*?\n\$\$;/i,
  )?.[0] || '';

  assert.match(offerFunction, /consideration_set_has_distinct_captains/i);
  assert.match(offerFunction, /vc\.assigned_seats\s*>\s*0/i);
});

test('T-72 and T-24 planners reject fleets that cannot be staffed distinctly', () => {
  const t72Planner = migration.match(
    /create or replace function pace_v2\.plan_t72_whole_party_allocations[\s\S]*?\n\$\$;/i,
  )?.[0] || '';
  const t24Planner = migration.match(
    /create or replace function pace_v2\.plan_t24_operator_consolidation[\s\S]*?\n\$\$;/i,
  )?.[0] || '';

  assert.match(t72Planner, /consideration_set_has_distinct_captains/i);
  assert.match(t24Planner, /consideration_set_has_distinct_captains/i);
});
