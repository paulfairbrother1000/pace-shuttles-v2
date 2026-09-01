type StripeCheckoutSession={
  id?:string; status?:string; payment_status?:string; amount_total?:number;
  currency?:string; client_reference_id?:string; metadata?:Record<string,string>;
  payment_intent?:string|{id?:string};
};

type CustomerOrder={order_id:string;total_cents:number;currency:string};

export function assertRecoverableCheckoutSession(session:StripeCheckoutSession,order:CustomerOrder,requestedSessionId:string){
  if(!requestedSessionId||session.id!==requestedSessionId)throw new Error('Stripe session does not match this request');
  if(session.status!=='complete'||session.payment_status!=='paid')throw new Error('Stripe payment is not complete');
  const stripeOrder=session.metadata?.order_id||session.client_reference_id;
  if(stripeOrder!==order.order_id||session.client_reference_id!==order.order_id)throw new Error('Stripe session does not match this order');
  if(Number(session.amount_total)!==Number(order.total_cents))throw new Error('Stripe payment amount does not match this order');
  if(String(session.currency||'').toUpperCase()!==String(order.currency||'').toUpperCase())throw new Error('Stripe payment currency does not match this order');
  const paymentIntentId=typeof session.payment_intent==='string'?session.payment_intent:session.payment_intent?.id;
  if(!paymentIntentId)throw new Error('Stripe payment intent is missing');
  return {sessionId:session.id, paymentIntentId, orderId:order.order_id};
}
