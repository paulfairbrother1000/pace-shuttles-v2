import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

test('book page uses only the native journey seat selector',()=>{
  const page=fs.readFileSync(new URL('../app/book/page.tsx',import.meta.url),'utf8');
  assert.doesNotMatch(page,/BookingCardEnhancements/);
});

test('native journey selector remains responsible for quote party size',()=>{
  const booking=fs.readFileSync(new URL('../components/customer-booking.tsx',import.meta.url),'utf8');
  assert.match(booking,/p_party_size:partyFor\(id\)/);
  assert.match(booking,/changeJourneyParty\(x\.departure_id,\+e\.target\.value\)/);
});
