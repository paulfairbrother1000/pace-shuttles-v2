import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

test('a minimum-achieved last vehicle continues selling its contiguous remaining seats at normal price',()=>{
  const sql=fs.readFileSync(new URL('../supabase/migrations/20260901023500_last_vehicle_remaining_capacity.sql',import.meta.url),'utf8');
  assert.match(sql,/LAST_VEHICLE_REMAINING_CAPACITY/);
  assert.match(sql,/t\.normal_target_seq is null/);
  assert.match(sql,/s\.min_met_count between 1 and 1/);
  assert.match(sql,/o\.remaining_capacity\s*>=\s*p_party_size/);
  assert.match(sql,/false as use_discount/);
  assert.match(sql,/o\.normal_price as offer_price/);
});
