import {describe,it,expect,vi} from 'vitest';
import {executeAdminStripeRefund} from './admin-refund-execution';
const action={refund_request_id:'request-1',payment_intent_id:'pi_1',amount_cents:5000,currency:'USD'};
const refund={id:'re_1',status:'succeeded',amount:5000,currency:'usd',payment_intent:'pi_1',metadata:{pace_refund_request_id:'request-1'}};
const response=(data:unknown)=>new Response(JSON.stringify(data),{status:200});
describe('admin refund Stripe execution',()=>{
 it('executes the exact approved amount with a stable idempotency key',async()=>{
  const fetcher=vi.fn().mockResolvedValueOnce(response({data:[],has_more:false})).mockResolvedValueOnce(response(refund));
  expect(await executeAdminStripeRefund(action,'secret',fetcher)).toEqual(refund);
  const request=fetcher.mock.calls[1];expect(request[1].headers['Idempotency-Key']).toBe('pace-admin-refund-request-1');
  expect(request[1].body.get('amount')).toBe('5000');expect(request[1].body.get('payment_intent')).toBe('pi_1');
 });
 it('reconciles a prior success after a lost response without creating another refund',async()=>{
  const fetcher=vi.fn().mockResolvedValue(response({data:[refund],has_more:false}));
  expect(await executeAdminStripeRefund(action,'secret',fetcher)).toEqual(refund);expect(fetcher).toHaveBeenCalledTimes(1);
 });
 it('retrieves a known pending refund and never issues another payment',async()=>{
  const fetcher=vi.fn().mockResolvedValue(response({...refund,status:'pending'}));
  const result=await executeAdminStripeRefund({...action,provider_refund_id:'re_1'},'secret',fetcher);
  expect(result.status).toBe('pending');expect(fetcher).toHaveBeenCalledTimes(1);expect(fetcher.mock.calls[0][0]).toContain('/refunds/re_1');
 });
 it.each([{...refund,amount:6000},{...refund,payment_intent:'pi_other'},{...refund,currency:'eur'},{...refund,metadata:{}}])('rejects mismatched provider evidence',async mismatched=>{
  const fetcher=vi.fn().mockResolvedValue(response(mismatched));
  await expect(executeAdminStripeRefund({...action,provider_refund_id:'re_1'},'secret',fetcher)).rejects.toThrow('does not match');
 });
 it('stops without creating a refund when reconciliation fails',async()=>{
  const fetcher=vi.fn().mockRejectedValue(new Error('timeout'));await expect(executeAdminStripeRefund(action,'secret',fetcher)).rejects.toThrow('timeout');expect(fetcher).toHaveBeenCalledTimes(1);
 });
});
