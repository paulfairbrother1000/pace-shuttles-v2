import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
import test from 'node:test';

const migrationsDir=new URL('../supabase/migrations/',import.meta.url);
const migrationName=readdirSync(migrationsDir).find(name=>name.endsWith('_improve_t24_client_email.sql'));
const sql=migrationName?readFileSync(new URL(migrationName,migrationsDir),'utf8'):'';

test('existing active pickup records receive an editable safe baseline instruction',()=>{
  assert.match(sql,/update pace_v2\.pickup_points/i);
  assert.match(sql,/set arrival_notes=/i);
  assert.match(sql,/nullif\(trim\(coalesce\(arrival_notes,''\)\),''\) is null/i);
  assert.match(sql,/Google Maps directions below/i);
});

test('T-24 scheduler requires and persists pickup meeting instructions',()=>{
  assert.ok(sql,'improved T-24 email migration is missing');
  assert.match(sql,/pp\.arrival_notes as pickup_arrival_notes/i);
  assert.match(sql,/missing pickup instructions/i);
  assert.match(sql,/'pickup_arrival_notes'\s*,\s*v_row\.pickup_arrival_notes/i);
  assert.match(sql,/'pickup_directions_url'\s*,\s*v_row\.pickup_directions_url/i);
});

test('queued fallback content omits empty passenger categories and includes arrival guidance',()=>{
  assert.match(sql,/concat_ws\(\s*' and '/i);
  assert.match(sql,/case when v_row\.adult_count>0/i);
  assert.match(sql,/Arrival at '[|]{2}v_row\.pickup_name/i);
  assert.match(sql,/If you have trouble locating the/i);
  assert.match(sql,/Contact Us/i);
});
