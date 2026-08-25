import test from 'node:test';
import assert from 'node:assert/strict';
import {CHECKOUT_OTP_LENGTH,normalizeCheckoutOtp,isCheckoutOtpComplete} from '../lib/checkout-otp.ts';

test('checkout accepts the 8-digit OTP Supabase emails',()=>{
  assert.equal(CHECKOUT_OTP_LENGTH,8);
  assert.equal(normalizeCheckoutOtp(' 41-51-34-26 '),'41513426');
  assert.equal(isCheckoutOtpComplete('41513426'),true);
  assert.equal(isCheckoutOtpComplete('415134'),false);
});
