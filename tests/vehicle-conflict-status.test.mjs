import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const migrationsDir=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../supabase/migrations');

test('admin vehicle considerations distinguish resource conflicts from genuine T-72 discards',()=>{
  const migrationName=fs.readdirSync(migrationsDir)
    .find(name=>name.endsWith('_show_conflicting_journey_for_unavailable_vehicle.sql'));

  assert.ok(migrationName,'conflicting-journey projection migration must exist');
  const sql=fs.readFileSync(path.join(migrationsDir,migrationName),'utf8');

  assert.match(sql,/create or replace view public\.v2_admin_vehicle_considerations/i);
  assert.match(sql,/confirmed_allocations[\s\S]*status\s*=\s*'confirmed'/i);
  assert.match(sql,/other_resource\.scheduled_start_ts\s*<\s*current_resource\.scheduled_end_ts/i);
  assert.match(sql,/other_resource\.scheduled_end_ts\s*>\s*current_resource\.scheduled_start_ts/i);
  assert.match(sql,/conflicting_departure_id/i);
  assert.match(sql,/other_allocation\.departure_id\s*<>\s*current_resource\.outbound_departure_id/i);
});

test('admin conflict projection authorizes only a checked Site Admin helper',()=>{
  const migrationName=fs.readdirSync(migrationsDir)
    .find(name=>name.endsWith('_secure_admin_vehicle_conflict_projection.sql'));

  assert.ok(migrationName,'secure conflict-projection migration must exist');
  const sql=fs.readFileSync(path.join(migrationsDir,migrationName),'utf8');

  assert.match(sql,/security definer/i);
  assert.match(sql,/if not pace_v2\.is_site_admin\(\) then[\s\S]*return null/i);
  assert.match(sql,/revoke all on function pace_v2\.site_admin_conflicting_departure_id\(uuid,uuid\)[\s\S]*from public,anon,authenticated,service_role/i);
  assert.match(sql,/grant execute on function pace_v2\.site_admin_conflicting_departure_id\(uuid,uuid\)[\s\S]*to authenticated/i);
  assert.match(sql,/pace_v2\.site_admin_conflicting_departure_id\(vc\.departure_id,vc\.vehicle_id\)[\s\S]*as conflicting_departure_id/i);
});
