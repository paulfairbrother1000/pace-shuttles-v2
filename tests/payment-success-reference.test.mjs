import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

test('payment success page shows the customer booking reference',()=>{
  const page=fs.readFileSync(new URL('../app/payment/success/page.tsx',import.meta.url),'utf8');
  assert.match(page,/Booking reference/);
  assert.match(page,/row\?\.booking_id/);
});
