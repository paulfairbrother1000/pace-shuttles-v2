import test from 'node:test';
import assert from 'node:assert/strict';
import {assertRecoverableCheckoutSession} from '../lib/stripe-payment-recovery.ts';

const order={order_id:'order-1',total_cents:5000,currency:'USD'};
const session={
  id:'cs_test_1',
  status:'complete',
  payment_status:'paid',
  amount_total:5000,
  currency:'usd',
  client_reference_id:'order-1',
  metadata:{order_id:'order-1'},
  payment_intent:'pi_test_1',
};

test('accepts only the paid Stripe session registered to the customer order',()=>{
  assert.deepEqual(assertRecoverableCheckoutSession(session,order,'cs_test_1'),{
    sessionId:'cs_test_1',paymentIntentId:'pi_test_1',orderId:'order-1',
  });
});

for(const [name,change] of [
  ['unpaid session',{payment_status:'unpaid'}],
  ['wrong order',{metadata:{order_id:'order-2'},client_reference_id:'order-2'}],
  ['wrong amount',{amount_total:4999}],
  ['wrong currency',{currency:'gbp'}],
  ['wrong session id',{id:'cs_test_other'}],
])test(`rejects ${name}`,()=>{
  assert.throws(()=>assertRecoverableCheckoutSession({...session,...change},order,'cs_test_1'));
});

test('success page sends its session id to the authenticated recovery endpoint',async()=>{
  const page=await import('node:fs').then(fs=>fs.readFileSync(new URL('../app/payment/success/page.tsx',import.meta.url),'utf8'));
  assert.match(page,/session_id/);
  assert.match(page,/\/api\/stripe\/confirm-checkout-session/);
  assert.match(page,/authorization/i);
});

test('webhook and recovery use the same deterministic refund idempotency key',async()=>{
  const fs=await import('node:fs');
  const webhook=fs.readFileSync(new URL('../app/api/stripe/webhook/route.ts',import.meta.url),'utf8');
  const recovery=fs.readFileSync(new URL('../app/api/stripe/confirm-checkout-session/route.ts',import.meta.url),'utf8');
  for(const source of [webhook,recovery]){
    assert.match(source,/'Idempotency-Key'/);
    assert.match(source,/pace-auto-refund-/);
  }
});
