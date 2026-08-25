import {NextResponse} from 'next/server';
import {createClient} from '@supabase/supabase-js';
import {dispatchDueCustomerEmails} from '@/lib/customer-email';
import crypto from 'crypto';
export const runtime='nodejs';

const SUPABASE_URL='https://prvzgvkuefcflvmepuhd.supabase.co';

function valid(payload:string,header:string,secret:string){
  const bits=Object.fromEntries(header.split(',').map(x=>x.split('=')));
  const t=bits.t;
  const v1=header.split(',').filter(x=>x.startsWith('v1=')).map(x=>x.slice(3));
  if(!t||!v1.length)return false;
  if(Math.abs(Date.now()/1000-Number(t))>300)return false;
  const expected=crypto.createHmac('sha256',secret).update(`${t}.${payload}`).digest('hex');
  return v1.some(x=>{try{return crypto.timingSafeEqual(Buffer.from(x),Buffer.from(expected))}catch{return false}})
}

async function stripeRefund(paymentIntent:string){
  const secret=process.env.STRIPE_SECRET_KEY||'';
  if(!secret)throw new Error('Missing setting: STRIPE_SECRET_KEY');
  const body=new URLSearchParams();
  body.set('payment_intent',paymentIntent);
  body.set('reason','requested_by_customer');
  const r=await fetch('https://api.stripe.com/v1/refunds',{method:'POST',headers:{Authorization:`Bearer ${secret}`,'Content-Type':'application/x-www-form-urlencoded'},body});
  const j=await r.json();
  if(!r.ok)throw new Error(j?.error?.message||'Automatic Stripe refund failed');
  return j
}

export async function POST(req:Request){
  const raw=await req.text();
  const sig=req.headers.get('stripe-signature')||'';
  const wh=process.env.STRIPE_WEBHOOK_SECRET||'';
  if(!wh)return new NextResponse('Missing setting: STRIPE_WEBHOOK_SECRET',{status:500});
  if(!valid(raw,sig,wh))return new NextResponse('Invalid signature',{status:400});

  const event=JSON.parse(raw);
  const obj=event.data?.object||{};
  const orderId=obj.metadata?.order_id||obj.client_reference_id;
  const key=process.env.SUPABASE_SERVICE_ROLE_KEY||'';
  if(!key)return new NextResponse('Missing setting: SUPABASE_SERVICE_ROLE_KEY',{status:500});

  const s=createClient(SUPABASE_URL,key,{auth:{persistSession:false}});
  try{
    if(orderId&&(event.type==='checkout.session.completed'||event.type==='checkout.session.async_payment_succeeded')){
      const {error:paidError}=await s.rpc('v2_system_mark_stripe_paid',{
        p_order_id:orderId,
        p_session_id:obj.id||'',
        p_payment_intent_id:typeof obj.payment_intent==='string'?obj.payment_intent:'',
        p_charge_id:null,
        p_payload:{event_id:event.id,event_type:event.type,payment_status:obj.payment_status}
      });
      if(paidError)throw paidError;

      const {data:pending,error:pendingError}=await s.rpc('v2_system_pending_automatic_refund',{p_order_id:orderId});
      if(pendingError)throw pendingError;
      const rr=pending?.[0];
      if(rr?.refund_request_id){
        const pi=rr.payment_intent_id||(typeof obj.payment_intent==='string'?obj.payment_intent:'');
        if(!pi)throw new Error('Automatic refund required but Stripe payment intent is missing');
        const refund=await stripeRefund(pi);
        const {error:recordError}=await s.rpc('v2_system_record_automatic_refund',{p_refund_request_id:rr.refund_request_id,p_provider_refund_ref:refund.id});
        if(recordError)throw recordError;
      }

      try{
        const emailResult=await dispatchDueCustomerEmails(25);
        if(emailResult.failed)console.error('One or more customer emails failed after payment',emailResult);
      }catch(emailError:any){
        console.error('Immediate customer email dispatch failed; scheduled retry remains available',emailError?.message||emailError);
      }
    }else if(orderId&&(event.type==='checkout.session.async_payment_failed'||event.type==='payment_intent.payment_failed')){
      const {error:failedError}=await s.rpc('v2_system_mark_stripe_failed',{
        p_order_id:orderId,
        p_session_id:obj.id||'',
        p_payment_intent_id:event.type==='payment_intent.payment_failed'?obj.id:(typeof obj.payment_intent==='string'?obj.payment_intent:''),
        p_failure:{event_id:event.id,event_type:event.type,last_payment_error:obj.last_payment_error||null}
      });
      if(failedError)throw failedError;
    }
    return NextResponse.json({received:true})
  }catch(e:any){
    return new NextResponse(e?.message||'Webhook processing failed',{status:500})
  }
}
