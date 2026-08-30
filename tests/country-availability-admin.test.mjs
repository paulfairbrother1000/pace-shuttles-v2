import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

test('Site Admin can pause and restore customer country availability with a required reason',()=>{
  const page=readFileSync('components/pages.tsx','utf8');
  const data=readFileSync('lib/data.ts','utf8');
  assert.match(data,/adminSetCountryCustomerAvailability/);
  assert.match(data,/v2_admin_set_country_customer_availability/);
  assert.match(page,/Pause customer availability/);
  assert.match(page,/Restore customer availability/);
  assert.match(page,/Reason is required/);
  assert.match(page,/customer_pause_reason/);
  assert.match(page,/customer_paused_at/);
  assert.match(page,/customer_paused_by/);
});
