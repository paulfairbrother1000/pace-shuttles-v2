import {createClient} from '@supabase/supabase-js';

type QueuedEmail={notification_id:string;to_email:string;subject:string|null;body:string|null;template_code:string|null;booking_id:string|null;departure_id:string|null};

const esc=(value:string)=>value.replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]||ch));

export function renderCustomerEmailHtml(subject:string,body:string){
 const linked=esc(body).replace(/(https:\/\/[^\s<]+)/g,'<a href="$1" style="color:#0877c9">$1</a>').replace(/\n/g,'<br/>');
 return `<!doctype html><html><body style="margin:0;background:#f4f7f9;font-family:Arial,sans-serif;color:#173042"><table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td align="center" style="padding:28px 12px"><table role="presentation" width="100%" style="max-width:640px;background:#ffffff;border-radius:14px;overflow:hidden"><tr><td style="padding:24px 30px;background:#0877c9;color:#fff"><div style="font-size:24px;font-weight:700">Pace Shuttles</div><div style="margin-top:5px;font-size:14px">Seamless journeys. One booking.</div></td></tr><tr><td style="padding:30px"><h1 style="font-size:24px;margin:0 0 22px">${esc(subject)}</h1><div style="font-size:15px;line-height:1.65">${linked}</div></td></tr><tr><td style="padding:20px 30px;border-top:1px solid #e5edf2;font-size:12px;color:#647681">Pace Shuttles · <a href="https://www.paceshuttles.com/customer" style="color:#0877c9">My Journeys</a> · hello@paceshuttles.com</td></tr></table></td></tr></table></body></html>`;
}

export async function dispatchDueCustomerEmails(limit=25){
 const url=process.env.NEXT_PUBLIC_SUPABASE_URL||'';const key=process.env.SUPABASE_SERVICE_ROLE_KEY||'';const resend=process.env.RESEND_API_KEY||'';
 if(!url||!key||!resend)throw new Error('Customer email service is not configured');
 const supabase=createClient(url,key,{auth:{persistSession:false}});
 const {data,error}=await supabase.rpc('v2_system_claim_due_customer_emails',{p_limit:limit});
 if(error)throw new Error(error.message);
 const rows=(data||[]) as QueuedEmail[];let sent=0,failed=0;
 for(const row of rows){
  try{
   const subject=row.subject||'Pace Shuttles update';const text=row.body||'';
   const response=await fetch('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${resend}`,'Content-Type':'application/json'},body:JSON.stringify({from:process.env.RESEND_FROM_EMAIL||'Pace Shuttles <hello@paceshuttles.com>',to:[row.to_email],subject,text,html:renderCustomerEmailHtml(subject,text)})});
   const result=await response.json().catch(()=>({}));
   if(!response.ok)throw new Error(result?.message||result?.error||`Resend returned ${response.status}`);
   const {error:markError}=await supabase.rpc('v2_system_mark_email_sent',{p_notification_id:row.notification_id,p_provider_reference:result?.id||null});
   if(markError)throw new Error(markError.message);sent++;
  }catch(e:any){failed++;const message=e?.message||'Unknown email failure';const {error:markError}=await supabase.rpc('v2_system_mark_email_failed',{p_notification_id:row.notification_id,p_failure_message:message});if(markError)console.error('Unable to mark email failed',row.notification_id,markError.message);}
 }
 return {claimed:rows.length,sent,failed};
}
