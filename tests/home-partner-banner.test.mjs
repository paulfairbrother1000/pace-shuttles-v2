import test from 'node:test';import assert from 'node:assert/strict';import {readFileSync} from 'node:fs';
test('homepage partner banner links to the V2 application page',()=>{const s=readFileSync('components/customer-booking.tsx','utf8');assert.match(s,/href="\/partners"/);assert.match(s,/Partner with Pace Shuttles/);assert.doesNotMatch(s,/pace-shuttles-v1|bopvaaexicvdueidyvjd/)});
