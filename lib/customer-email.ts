import {createClient} from '@supabase/supabase-js';
import {buildJourneyBroadcastEmail,type JourneyBroadcastCategory} from './journey-broadcast-email';
import {buildFeedbackEmail} from './feedback-email-content';

type JourneyBroadcastMetadata={journey_broadcast_delivery_id:string;pickup_name:string;destination_name:string;captain_name:string;category:JourneyBroadcastCategory;message:string};
type FeedbackMetadata={first_name:string;country_name:string;pickup_name:string;destination_name:string;feedback_url:string};
type QueuedEmail={notification_id:string;to_email:string;subject:string|null;body:string|null;template_code:string|null;booking_id:string|null;departure_id:string|null;metadata?:JourneyBroadcastMetadata|Record<string,unknown>|null};
type EmailClient={rpc:(name:string,args?:Record<string,unknown>)=>Promise<any>};
type CustomerEmailDependencies={env?:Record<string,string|undefined>;createClient?:(url:string,key:string,options:unknown)=>EmailClient;fetchImpl?:typeof fetch};

const esc=(value:string)=>value.replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]||ch));
const nl=(value:string)=>value.replace(/\n/g,'<br/>');
const hasValidRecipientEmail=(value:string|undefined)=>!!value?.trim()&&/^[^\s@]+@[^\s@]+[.][^\s@]+$/.test(value.trim());

function linkifyCustomerEmailText(body:string){
 let html='';let cursor=0;const urls=/https:\/\/[^\s<>"'\]\}\)]+/g;
 for(const match of body.matchAll(urls)){
  const start=match.index||0;const raw=match[0];const target=raw.replace(/[.,;:!?]+$/,'');
  html+=nl(esc(body.slice(cursor,start)));
  if(target)html+=`<a href="${esc(target)}" style="color:#0877c9">${esc(target)}</a>${nl(esc(raw.slice(target.length)))}`;
  else html+=nl(esc(raw));
  cursor=start+raw.length;
 }
 return html+nl(esc(body.slice(cursor)));
}

export function renderCustomerEmailHtml(subject:string,body:string){
 const linked=linkifyCustomerEmailText(body);
 return `<!doctype html><html><body style="margin:0;background:#f4f7f9;font-family:Arial,sans-serif;color:#173042"><table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td align="center" style="padding:28px 12px"><table role="presentation" width="100%" style="max-width:640px;background:#ffffff;border-radius:14px;overflow:hidden"><tr><td style="padding:24px 30px;background:#0877c9;color:#fff"><div style="font-size:24px;font-weight:700">Pace Shuttles</div><div style="margin-top:5px;font-size:14px">Seamless journeys. One booking.</div></td></tr><tr><td style="padding:30px"><h1 style="font-size:24px;margin:0 0 22px">${esc(subject)}</h1><div style="font-size:15px;line-height:1.65">${linked}</div></td></tr><tr><td style="padding:20px 30px;border-top:1px solid #e5edf2;font-size:12px;color:#647681">Pace Shuttles · <a href="https://www.paceshuttles.com/customer" style="color:#0877c9">My Journeys</a> · hello@paceshuttles.com</td></tr></table></td></tr></table></body></html>`;
}

export async function dispatchDueCustomerEmails(limit=25,deps:CustomerEmailDependencies={}){
 const env=deps.env||process.env;const url=env.NEXT_PUBLIC_SUPABASE_URL||'';const key=env.SUPABASE_SERVICE_ROLE_KEY||'';const resend=env.RESEND_API_KEY||'';
 if(!url||!key||!resend)throw new Error('Customer email service is not configured');
 const supabase=(deps.createClient||createClient as unknown as CustomerEmailDependencies['createClient'])!(url,key,{auth:{persistSession:false}});
 const fetchImpl=deps.fetchImpl||fetch;
 const {data,error}=await supabase.rpc('v2_system_claim_due_customer_emails_with_metadata',{p_limit:limit});
 if(error)throw new Error(error.message);
 const rows=(data||[]) as QueuedEmail[];let sent=0,failed=0;
 for(const row of rows){
  try{
   if(!hasValidRecipientEmail(row.to_email))throw new Error('Recipient email is unavailable or invalid');
   const metadata=row.metadata as JourneyBroadcastMetadata|undefined;
   const broadcast=row.template_code==='journey_broadcast'&&metadata ? buildJourneyBroadcastEmail({pickupName:metadata.pickup_name,destinationName:metadata.destination_name,captainName:metadata.captain_name,category:metadata.category,message:metadata.message}) : null;
   const feedbackMetadata=row.metadata as FeedbackMetadata|undefined;
   const feedback=row.template_code==='post_journey_feedback'&&feedbackMetadata?buildFeedbackEmail({firstName:feedbackMetadata.first_name,countryName:feedbackMetadata.country_name,pickupName:feedbackMetadata.pickup_name,destinationName:feedbackMetadata.destination_name,feedbackUrl:feedbackMetadata.feedback_url}):null;
   const subject=feedback?.subject||broadcast?.subject||row.subject||'Pace Shuttles update';const text=feedback?.text||broadcast?.text||row.body||'';
   const response=await fetchImpl('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${resend}`,'Content-Type':'application/json','Idempotency-Key':`pace-notification-${row.notification_id}`},body:JSON.stringify({from:env.RESEND_FROM_EMAIL||'Pace Shuttles <hello@paceshuttles.com>',to:[row.to_email],subject,text,html:renderCustomerEmailHtml(subject,text)})});
   const result=await response.json().catch(()=>({}));
   if(!response.ok)throw new Error(result?.message||result?.error||`Resend returned ${response.status}`);
   const deliveryId=(row.metadata as JourneyBroadcastMetadata|undefined)?.journey_broadcast_delivery_id;
   const {error:markError}=await supabase.rpc(deliveryId?'v2_system_mark_journey_broadcast_email_sent':'v2_system_mark_email_sent',deliveryId?{p_notification_id:row.notification_id,p_delivery_id:deliveryId,p_provider_reference:result?.id||null}:{p_notification_id:row.notification_id,p_provider_reference:result?.id||null});
   if(markError)throw new Error(markError.message);sent++;
  }catch(e:any){failed++;const message=e?.message||'Unknown email failure';const deliveryId=(row.metadata as JourneyBroadcastMetadata|undefined)?.journey_broadcast_delivery_id;const {error:markError}=await supabase.rpc(deliveryId?'v2_system_mark_journey_broadcast_email_failed':'v2_system_mark_email_failed',deliveryId?{p_notification_id:row.notification_id,p_delivery_id:deliveryId,p_failure_message:message}:{p_notification_id:row.notification_id,p_failure_message:message});if(markError)console.error('Unable to mark email failed',row.notification_id,markError.message);}
 }
 return {claimed:rows.length,sent,failed};
}
