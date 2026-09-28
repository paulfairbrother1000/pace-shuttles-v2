import {createClient} from '@supabase/supabase-js';

type MissingSlotAlert={alert_id:string;recipient_email:string;expected_at:string;detected_at:string;resolved_at?:string|null;impact_summary?:string|null};
type AlertDependencies={env?:Record<string,string|undefined>;createClient?:(url:string,key:string,options:unknown)=>{rpc:(name:string,args?:Record<string,unknown>)=>Promise<any>};fetchImpl?:typeof fetch};
const escapeHtml=(s:string)=>s.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]||c));

export function buildMissingSlotAlert(row:MissingSlotAlert){
 const subject='MISSED: Pace Shuttles hourly scheduled job was not invoked';
 const text=[
  'A scheduled hourly invocation was not recorded.',
  `Expected UTC hour: ${row.expected_at}`,
  `Detected: ${row.detected_at}`,
  `Impact: ${row.impact_summary||'T-72/T-24, feedback scheduling and email delivery may have been delayed.'}`,
  `Recovery: ${row.resolved_at||'No later successful scheduled run recorded.'}`,
  'Review phase evidence: https://www.paceshuttles.com/admin/clock-calendar',
 ].join('\n');
 return {subject,text,html:`<html><body><pre style="font-family:Arial,sans-serif;white-space:pre-wrap">${escapeHtml(text)}</pre></body></html>`};
}

export async function dispatchMissingSlotAlerts(limit=25,deps:AlertDependencies={}){
 const env=deps.env||process.env,url=env.NEXT_PUBLIC_SUPABASE_URL||'',key=env.SUPABASE_SERVICE_ROLE_KEY||'',resend=env.RESEND_API_KEY||'';
 if(!url||!key||!resend)throw new Error('Scheduler missing-slot alert service is not configured');
 const client=(deps.createClient||createClient as unknown as NonNullable<AlertDependencies['createClient']>)(url,key,{auth:{persistSession:false}});
 const claimed=await client.rpc('v2_system_claim_missing_slot_alerts',{p_limit:limit});
 if(claimed.error)throw new Error(claimed.error.message);
 const rows=(claimed.data||[]) as MissingSlotAlert[];let sent=0,failed=0;
 for(const row of rows){
  try{
   if(!/^[^\s@]+@[^\s@]+[.][^\s@]+$/.test(row.recipient_email))throw new Error('Invalid Site Admin email');
   const mail=buildMissingSlotAlert(row);
   const response=await (deps.fetchImpl||fetch)('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${resend}`,'Content-Type':'application/json','Idempotency-Key':`pace-missing-slot-${row.alert_id}`},body:JSON.stringify({from:env.RESEND_FROM_EMAIL||'Pace Shuttles <hello@paceshuttles.com>',to:[row.recipient_email],...mail})});
   const result=await response.json().catch(()=>({}));
   if(!response.ok)throw new Error(result?.message||`Resend returned ${response.status}`);
   const marked=await client.rpc('v2_system_mark_missing_slot_alert_sent',{p_alert_id:row.alert_id,p_provider_reference:result?.id||null});
   if(marked.error)throw new Error(marked.error.message);
   sent++;
  }catch(error){
   failed++;
   const marked=await client.rpc('v2_system_mark_missing_slot_alert_failed',{p_alert_id:row.alert_id,p_failure_reason:error instanceof Error?error.message:'Unknown alert failure'});
   if(marked.error)console.error('Could not record missed-slot alert failure',marked.error.message);
  }
 }
 return {claimed:rows.length,sent,failed};
}
