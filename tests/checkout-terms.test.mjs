import test from 'node:test';
import assert from 'node:assert/strict';
import {canStartPayment,termsAcceptanceCopy} from '../lib/checkout-terms.js';

test('payment requires terms acceptance and idle state',()=>{
 assert.equal(canStartPayment(false,false),false);
 assert.equal(canStartPayment(true,true),false);
 assert.equal(canStartPayment(true,false),true);
});

test('acceptance copy identifies country and version',()=>{
 assert.match(termsAcceptanceCopy('Antigua and Barbuda','2025-10-24'),/Antigua and Barbuda/);
 assert.match(termsAcceptanceCopy('Antigua and Barbuda','2025-10-24'),/2025-10-24/);
});
