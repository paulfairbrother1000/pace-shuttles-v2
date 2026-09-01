import {NextResponse} from 'next/server';
import {createClient} from '@supabase/supabase-js';
import {assertRecoverableCheckoutSession} from '@/lib/stripe-payment-recovery';
import {dispatchDueCustomerEmails} from '@/lib/customer-email';

export const runtime='nodejs';

async function stripeGet(path:string,secret:string){
  const r=await fetch(`https://api.stripe.com/v1/${path}`,{headers:{Authorization:`Bearer ${secret}`},cache:'no-store'});
  const j=await r.json();
  if(!r.ok)throw new Error(j?.error?.message||'Stripe request failed');
  return j;
}

async function stripeRefund(paymentIntent:string,secret:string){
  const body=new URLSearchParams({payment_intent:paymentIntent,reason:'requested_by_customer'});
  const r=await fetch('https://api.stripe.com/v1/refunds',{method:'POST',headers:{Authorization:`Bearer ${secret}`,'Content-Type':'application/x-www-form-urlencoded','Idempotency-Key':`pace-auto-refund-${paymentIntent}`},body});
  const j=await r.json();
  if(!r.ok)throw new Error(j?.error?.message||'Automatic Stripe refund failed');
  return j;
}

export async function POST(req:Request){
  let orderId=''; let sessionId='';
  try{
    const token=(req.headers.get('authorization')||'').replace(/^Bearer\s+/i,'');
    if(!token)return NextResponse.json({error:'Sign in required'},{status:401});
    ({orderId,sessionId}=await req.json());
    if(!orderId||!sessionId)return NextResponse.json({error:'Order and Stripe session are required'},{status:400});
    const url=process.env.NEXT_PUBLIC_SUPABASE_URL||'';
    const anon=process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY||'';
    const service=process.env.SUPABASE_SERVICE_ROLE_KEY||'';
    const stripeSecret=process.env.STRIPE_SECRET_KEY||'';
    if(!url||!anon||!service||!stripeSecret)return NextResponse.json({error:'Payment recovery is not configured'},{status:503});

    const userClient=createClient(url,anon,{global:{headers:{Authorization:`Bearer ${token}`}}});
    const {data:{user}}=await userClient.auth.getUser(token);
    if(!user)return NextResponse.json({error:'Sign in required'},{status:401});
    const {data,error}=await userClient.rpc('v2_customer_order_payment_context',{p_order_id:orderId});
    const order=data?.[0];
    if(error||!order)return NextResponse.json({error:error?.message||'Order not found'},{status:404});

    const session=await stripeGet(`checkout/sessions/${encodeURIComponent(sessionId)}`,stripeSecret);
    const verified=assertRecoverableCheckoutSession(session,order,sessionId);
    const admin=createClient(url,service,{auth:{persistSession:false}});
    const {error:paidError}=await admin.rpc('v2_system_mark_stripe_paid',{p_order_id:orderId,p_session_id:verified.sessionId,p_payment_intent_id:verified.paymentIntentId,p_charge_id:null,p_payload:{source:'authenticated_success_recovery',payment_status:session.payment_status}});
    if(paidError)throw paidError;
    const {data:pending,error:pendingError}=await admin.rpc('v2_system_pending_automatic_refund',{p_order_id:orderId});
    if(pendingError)throw pendingError;
    const rr=pending?.[0];
    if(rr?.refund_request_id){
      const refund=await stripeRefund(rr.payment_intent_id||verified.paymentIntentId,stripeSecret);
      const {error:recordError}=await admin.rpc('v2_system_record_automatic_refund',{p_refund_request_id:rr.refund_request_id,p_provider_refund_ref:refund.id});
      if(recordError)throw recordError;
    }
    dispatchDueCustomerEmails(25).catch(e=>console.error('Customer email dispatch deferred after payment recovery',{orderId,error:e?.message||String(e)}));
    return NextResponse.json({reconciled:true});
  }catch(e:any){
    console.error('Authenticated Stripe payment recovery failed',{orderId,sessionId,error:e?.message||String(e)});
    return NextResponse.json({error:e?.message||'Unable to confirm payment'},{status:500});
  }
}
