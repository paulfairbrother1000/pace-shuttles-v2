import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

test('homepage uses the approved V1-inspired introduction and supplied logo',()=>{
  const page=readFileSync('components/customer-booking.tsx','utf8');
  assert.match(page,/Discover a new way to move between exclusive islands and shores with semi private, shared charters that blend exclusivity with ease\./);
  assert.match(page,/Discover some of the finest beach clubs, restaurants and bars in style, where every journey feels like a vacation of its own\./);
  assert.match(page,/We connect travellers, operators and destinations through one intelligent platform that handles booking, payments, scheduling and customer care/);
  assert.match(page,/src="\/paceshuttles-logo\.jpeg"/);
  const logo=readFileSync('public/paceshuttles-logo.jpeg');
  assert.ok(logo.length>40000,'supplied full-resolution logo should be present');
});