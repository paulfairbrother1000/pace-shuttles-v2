import {createClient} from '@supabase/supabase-js';

type AlertPhase={phase:string;status:string;started_at?:string|null;finished_at?:string|null;failure_reason?:string|null;result?:unknown};
export type SchedulerAdminAlert={
 alert_id:string;alert_type:'failure'|'recovery';run_id:string;recipient_email:string;
 requested_at?:string|null;started_at?:string|null;finished_at?:string|null;
 failure_phase?:string|null;failure_reason?:string|null;impact_summary?:string|null;
 resolved_at?:string|null;resolution_summary?:string|null;result?:unknown;phases?:AlertPhase[];
};
type AlertClient={rpc:(name:string,args?:Record<string,unknown>)=>Promise<any>};
type AlertDependencies={env?:Record<string,string|undefined>;createClient?:(url:string,key:string,options:unknown)=>AlertClient;fetchImpl?:typeof fetch};

const phaseLabels:Record<string,string>={journey_operations:'Journey operations',t24_communications:'T-24 communications',feedback_communications:'Feedback communications',email_delivery:'Email delivery'};
const label=(value?:string|null)=>value?phaseLabels[value]||value.replaceAll('_',' '):'Not recorded';
const seconds=(start?:string|null,finish?:string|null)=>start&&finish?Math.max(0,Math.round((new Date(finish).getTime()-new Date(start).getTime())/1000)):null;
const time=(value?:string|null)=>value?new Date(value).toISOString():'Not recorded';
const json=(value:unknown)=>JSON.stringify(value??{},null,2);
const esc=(value:string)=>value.replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]||ch));

export function buildSchedulerAdminAlert(row:SchedulerAdminAlert){
 const recovery=row.alert_type==='recovery';
 const duration=seconds(row.started_at,row.finished_at);
 const history='https://www.paceshuttles.com/admin/clock-calendar';
 const phaseLog=(row.phases||[]).map(phase=>{
  const phaseDuration=seconds(phase.started_at,phase.finished_at);
  return `- ${label(phase.phase)} | ${label(phase.status)} | ${phaseDuration===null?'duration unavailable':`${phaseDuration} seconds`}${phase.failure_reason?` | ${phase.failure_reason}`:''}\n  Result: ${json(phase.result)}`;
 }).join('\n');
 const text=recovery?[
  'Pace Shuttles scheduled job recovered.','',`Failed run ID: ${row.run_id}`,`Original failure: ${row.failure_reason||'Not recorded'}`,`Impact: ${row.impact_summary||'Not recorded'}`,`Resolved at: ${time(row.resolved_at)}`,`Resolution: ${row.resolution_summary||'A later scheduled run completed successfully.'}`,'',`Execution history: ${history}`,
 ].join('\n'):[
  'Pace Shuttles scheduled job failed. Immediate Site Admin review is required.','',`Run ID: ${row.run_id}`,`Requested: ${time(row.requested_at)}`,`Started: ${time(row.started_at)}`,`Finished: ${time(row.finished_at)}`,`Duration: ${duration===null?'Not recorded':`${duration} seconds`}`,`Failed phase: ${label(row.failure_phase)}`,`Failure reason: ${row.failure_reason||'Not recorded'}`,`Impact: ${row.impact_summary||'Not recorded'}`,'',`Partial result:\n${json(row.result)}`,'',`Phase log:\n${phaseLog||'No phase records were captured.'}`,'',`Execution history: ${history}`,
 ].join('\n');
 const subject=recovery?'RESOLVED: Pace Shuttles scheduled job recovered':'ACTION REQUIRED: Pace Shuttles scheduled job failed';
 return {subject,text,html:`<!doctype html><html><body style="font-family:Arial,sans-serif;color:#173042"><h1>${esc(subject)}</h1><pre style="white-space:pre-wrap;font-family:Arial,sans-serif">${esc(text)}</pre></body></html>`};
}

export async function dispatchSchedulerAdminAlerts(limit=25,deps:AlertDependencies={}){
 const env=deps.env||process.env,url=env.NEXT_PUBLIC_SUPABASE_URL||'',key=env.SUPABASE_SERVICE_ROLE_KEY||'',resend=env.RESEND_API_KEY||'';
 if(!url||!key||!resend)throw new Error('Scheduler Site Admin alert service is not configured');
 const client=(deps.createClient||createClient as unknown as AlertDependencies['createClient'])!(url,key,{auth:{persistSession:false}});
 const fetchImpl=deps.fetchImpl||fetch;
 const claimed=await client.rpc('v2_system_claim_scheduler_admin_alerts',{p_limit:limit});
 if(claimed.error)throw new Error(claimed.error.message);
 const rows=(claimed.data||[]) as SchedulerAdminAlert[];let sent=0,failed=0;
 for(const row of rows){
  try{
   if(!/^[^\s@]+@[^\s@]+[.][^\s@]+$/.test(row.recipient_email||''))throw new Error('Site Admin recipient email is invalid');
   const message=buildSchedulerAdminAlert(row);
   const response=await fetchImpl('https://api.resend.com/emails',{method:'POST',headers:{Authorization:`Bearer ${resend}`,'Content-Type':'application/json','Idempotency-Key':`pace-scheduler-alert-${row.alert_id}`},body:JSON.stringify({from:env.RESEND_FROM_EMAIL||'Pace Shuttles <hello@paceshuttles.com>',to:[row.recipient_email],subject:message.subject,text:message.text,html:message.html})});
   const result=await response.json().catch(()=>({}));
   if(!response.ok)throw new Error(result?.message||result?.error||`Resend returned ${response.status}`);
   const marked=await client.rpc('v2_system_mark_scheduler_admin_alert_sent',{p_alert_id:row.alert_id,p_provider_reference:result?.id||null});
   if(marked.error)throw new Error(marked.error.message);
   sent++;
  }catch(error:unknown){
   failed++;const reason=error instanceof Error?error.message:'Scheduler Site Admin alert failed';
   await client.rpc('v2_system_mark_scheduler_admin_alert_failed',{p_alert_id:row.alert_id,p_failure_reason:reason});
  }
 }
 return {claimed:rows.length,sent,failed};
}
