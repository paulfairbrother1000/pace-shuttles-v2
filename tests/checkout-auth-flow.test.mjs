import test from 'node:test';
import assert from 'node:assert/strict';
import {checkoutResumePath,checkoutAuthCopy} from '../lib/checkout-auth-flow.js';

test('checkout resume path keeps the same quote id',()=>{
  assert.equal(checkoutResumePath('quote 123'),'/checkout?q=quote%20123&resume=1');
});

test('checkout auth copy keeps payment as the customer intent',()=>{
  const copy=checkoutAuthCopy();
  assert.equal(copy.primaryAction,'Continue to payment');
  assert.equal(copy.heading,'Confirm your email to continue');
  assert.equal(copy.emailAction,'Send confirmation email');
});
