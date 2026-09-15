import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import ts from 'typescript';

async function loadAlerts(){
 const source=readFileSync(new URL('../lib/scheduler-admin-alerts.ts',import.meta.url),'utf8')
  .replace("import {createClient} from '@supabase/supabase-js';",'');
 const compiled=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
 return import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`);
}

const failed={
 alert_id:'alert-1',alert_type:'failure',run_id:'run-42',recipient_email:'admin@paceshuttles.com',
 requested_at:'2026-09-15T22:00:08Z',started_at:'2026-09-15T22:00:08Z',finished_at:'2026-09-15T22:02:08Z',
 failure_phase:'journey_operations',failure_reason:'upstream request timeout',
 impact_summary:'No journey lifecycle changes committed; later phases did not run.',resolution_summary:null,
 result:{operations:{generated_departures:0,t72_processed:0,t24_processed:0}},
 phases:[{phase:'journey_operations',status:'failed',started_at:'2026-09-15T22:00:08Z',finished_at:'2026-09-15T22:02:08Z',failure_reason:'upstream request timeout',result:{}}],
};
const env={NEXT_PUBLIC_SUPABASE_URL:'https://example.supabase.co',SUPABASE_SERVICE_ROLE_KEY:'server-secret',RESEND_API_KEY:'resend-secret',RESEND_FROM_EMAIL:'Pace Shuttles <hello@paceshuttles.com>',NEXT_PUBLIC_SITE_URL:'https://www.paceshuttles.com'};

test('failure email contains the run, phase, reason, impact, phase log and history link',async()=>{
 const {buildSchedulerAdminAlert}=await loadAlerts();
 const message=buildSchedulerAdminAlert(failed);
 assert.equal(message.subject,'ACTION REQUIRED: Pace Shuttles scheduled job failed');
 for(const evidence of ['run-42','Journey operations','upstream request timeout','No journey lifecycle changes committed','120 seconds','/admin/clock-calendar'])assert.match(message.text,new RegExp(evidence));
});

test('dispatcher uses delivery identity for idempotency and marks accepted mail sent',async()=>{
 const {dispatchSchedulerAdminAlerts}=await loadAlerts();const calls=[];let outbound;
 const result=await dispatchSchedulerAdminAlerts(10,{
  env,createClient:()=>({rpc:async(name,args)=>{calls.push([name,args]);if(name==='v2_system_claim_scheduler_admin_alerts')return {data:[failed],error:null};return {data:null,error:null}}}),
  fetchImpl:async(_url,request)=>{outbound={headers:request.headers,body:JSON.parse(request.body)};return {ok:true,json:async()=>({id:'resend-alert-1'})};},
 });
 assert.deepEqual(result,{claimed:1,sent:1,failed:0});
 assert.equal(outbound.headers['Idempotency-Key'],'pace-scheduler-alert-alert-1');
 assert.equal(outbound.body.to[0],'admin@paceshuttles.com');
 assert.deepEqual(calls.at(-1),['v2_system_mark_scheduler_admin_alert_sent',{p_alert_id:'alert-1',p_provider_reference:'resend-alert-1'}]);
});

test('provider failure is retained for a later scheduler retry',async()=>{
 const {dispatchSchedulerAdminAlerts}=await loadAlerts();const calls=[];
 const result=await dispatchSchedulerAdminAlerts(10,{
  env,createClient:()=>({rpc:async(name,args)=>{calls.push([name,args]);if(name==='v2_system_claim_scheduler_admin_alerts')return {data:[failed],error:null};return {data:null,error:null}}}),
  fetchImpl:async()=>({ok:false,status:503,json:async()=>({message:'provider unavailable'})}),
 });
 assert.deepEqual(result,{claimed:1,sent:0,failed:1});
 assert.deepEqual(calls.at(-1),['v2_system_mark_scheduler_admin_alert_failed',{p_alert_id:'alert-1',p_failure_reason:'provider unavailable'}]);
});

test('recovery email names the failed run and its recorded resolution',async()=>{
 const {buildSchedulerAdminAlert}=await loadAlerts();
 const message=buildSchedulerAdminAlert({...failed,alert_type:'recovery',resolved_at:'2026-09-15T23:00:04Z',resolution_summary:'Resolved by successful scheduled run at 2026-09-15 23:00:04 UTC.'});
 assert.equal(message.subject,'RESOLVED: Pace Shuttles scheduled job recovered');
 assert.match(message.text,/run-42/);
 assert.match(message.text,/Resolved by successful scheduled run/);
});
