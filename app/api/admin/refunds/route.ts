import {NextResponse} from 'next/server';
import {createClient} from '@supabase/supabase-js';
import {executeAdminStripeRefund} from '@/lib/admin-refund-execution';
export const runtime='nodejs';
export async function POST(req:Request){
 const token=(req.headers.get('authorization')||'').replace(/^Bearer\s+/i,'');
 if(!token)return NextResponse.json({error:'Site Admin sign-in required'},{status:401});
 const url=process.env.NEXT_PUBLIC_SUPABASE_URL||'',anon=process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY||'';
 const service=process.env.SUPABASE_SERVICE_ROLE_KEY||'',stripe=process.env.STRIPE_SECRET_KEY||'';
 if(!url||!anon||!service)return NextResponse.json({error:'Refund service is unavailable'},{status:503});
 const userClient=createClient(url,anon,{global:{headers:{Authorization:`Bearer ${token}`}},auth:{persistSession:false}});
 const {data:{user},error:authError}=await userClient.auth.getUser(token);
 if(authError||!user)return NextResponse.json({error:'Sign in required'},{status:401});
 let action:any;let refundRequestId='';
 const system=createClient(url,service,{auth:{persistSession:false}});
 try{
  const body=await req.json();refundRequestId=body.refundRequestId;
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(refundRequestId||'')||!['execute','decline'].includes(body.action))return NextResponse.json({error:'Invalid refund action'},{status:400});
  // Every financial RPC checks Site Admin membership server-side.
  const context=await userClient.rpc('v2_admin_refund_action_context',{p_refund_request_id:refundRequestId});
  if(context.error)return NextResponse.json({error:context.error.message},{status:403});
  if(body.action==='decline'){
   const result=await userClient.rpc('v2_admin_decline_refund',{p_refund_request_id:refundRequestId});
   if(result.error)return NextResponse.json({error:result.error.message},{status:409});
   return NextResponse.json({status:'declined'});
  }
  if(!stripe)return NextResponse.json({error:'Stripe refund execution is not configured'},{status:503});
  const begin=await userClient.rpc('v2_admin_begin_refund_execution',{p_refund_request_id:refundRequestId});
  if(begin.error)return NextResponse.json({error:begin.error.message},{status:409});
  action=begin.data;
  if(action.status==='paid')return NextResponse.json({status:'paid'});
  const refund=await executeAdminStripeRefund(action,stripe);
  const pi=typeof refund.payment_intent==='string'?refund.payment_intent:refund.payment_intent.id;
  const finish=await system.rpc('v2_system_finish_admin_refund',{p_refund_request_id:refundRequestId,p_provider_refund_id:refund.id,p_status:refund.status,p_amount_cents:refund.amount,p_currency:refund.currency,p_payment_intent_id:pi,p_failure_reason:refund.failure_reason||null});
  if(finish.error)throw new Error(`Stripe result received; recording requires retry: ${finish.error.message}`);
  return NextResponse.json({status:refund.status==='succeeded'?'paid':refund.status,providerReference:refund.id});
 }catch(error:any){
  if(action?.refund_request_id&&!action.provider_refund_id){
   await system.rpc('v2_system_finish_admin_refund',{p_refund_request_id:refundRequestId,p_provider_refund_id:null,p_status:'retryable',p_amount_cents:action.amount_cents,p_currency:action.currency,p_payment_intent_id:action.payment_intent_id,p_failure_reason:error?.message||'Refund requires reconciliation'});
  }
  console.error('Admin refund execution requires attention',{refundRequestId,error:error?.message});
  return NextResponse.json({error:error?.message||'Refund requires reconciliation. Retry to check its existing Stripe status.'},{status:502});
 }
}
