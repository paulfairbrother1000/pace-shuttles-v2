type RefundExecution={refund_request_id:string;payment_intent_id:string;amount_cents:number;currency:string;provider_refund_id?:string|null};
type StripeRefund={id:string;status:string;amount:number;currency:string;payment_intent:string|{id:string};metadata?:Record<string,string>;failure_reason?:string};
export async function executeAdminStripeRefund(action:RefundExecution,secret:string,fetchImpl:typeof fetch=fetch){
 const request=async(path:string,init:RequestInit={})=>{
  const response=await fetchImpl('https://api.stripe.com/v1/'+path,{...init,headers:{Authorization:`Bearer ${secret}`,...init.headers},signal:AbortSignal.timeout(20000),cache:'no-store'});
  const body=await response.json();if(!response.ok)throw new Error(body?.error?.message||`Stripe returned ${response.status}`);return body;
 };
 const verify=(refund:StripeRefund)=>{
  const pi=typeof refund.payment_intent==='string'?refund.payment_intent:refund.payment_intent?.id;
  if(pi!==action.payment_intent_id||refund.amount!==action.amount_cents||refund.currency.toLowerCase()!==action.currency.toLowerCase()
    ||refund.metadata?.pace_refund_request_id!==action.refund_request_id)throw new Error('Stripe refund does not match this approved refund request');
  return refund;
 };
 if(action.provider_refund_id)return verify(await request(`refunds/${encodeURIComponent(action.provider_refund_id)}`));
 // Reconcile before retrying, including after Stripe's idempotency-key retention window.
 let after='';
 for(let page=0;page<20;page++){
  const query=new URLSearchParams({payment_intent:action.payment_intent_id,limit:'100'});if(after)query.set('starting_after',after);
  const list=await request(`refunds?${query}`);
  const existing=(list.data||[]).find((r:StripeRefund)=>r.metadata?.pace_refund_request_id===action.refund_request_id);
  if(existing)return verify(existing);
  if(!list.has_more)break;
  after=list.data?.at(-1)?.id;if(!after||page===19)throw new Error('Unable to reconcile all existing refunds; review in Finance');
 }
 const body=new URLSearchParams({payment_intent:action.payment_intent_id,amount:String(action.amount_cents),'metadata[pace_refund_request_id]':action.refund_request_id});
 return verify(await request('refunds',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded','Idempotency-Key':`pace-admin-refund-${action.refund_request_id}`},body}));
}
