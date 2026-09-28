import assert from 'node:assert/strict';
import test from 'node:test';
import ts from 'typescript';
import {readFileSync} from 'node:fs';

async function loadHandler(){const source=readFileSync(new URL('../lib/admin-scheduler-handler.ts',import.meta.url),'utf8').replace(/^import .*;\s*$/gm,'');const shim=`const NextResponse={json:(body,init={})=>new Response(JSON.stringify(body),{status:init.status??200,headers:{'content-type':'application/json'}})};\n`;const js=ts.transpileModule(shim+source,{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;return import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`)}
const env={NEXT_PUBLIC_SUPABASE_URL:'https://example.supabase.co',NEXT_PUBLIC_SUPABASE_ANON_KEY:'anon',SUPABASE_SERVICE_ROLE_KEY:'service'};
const request=(method,body,token='token')=>new Request('https://example.test/api/admin/scheduler',{method,headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:body?JSON.stringify(body):undefined});

test('admin scheduler rejects missing authentication before privileged work',async()=>{const {createAdminSchedulerHandler}=await loadHandler();let clients=0;const handler=createAdminSchedulerHandler({env,now:()=>new Date().toISOString(),createUserClient:()=>{clients++;return{}},createServiceClient:()=>{clients++;return{}},dispatchDueCustomerEmails:async()=>({claimed:0,sent:0,failed:0})});const response=await handler(new Request('https://example.test',{method:'GET'}));assert.equal(response.status,401);assert.equal(clients,0)});

test('GET returns the protected dashboard and calendar',async()=>{const {createAdminSchedulerHandler}=await loadHandler();const calls=[];const handler=createAdminSchedulerHandler({env,now:()=> '2026-09-13T12:00:00Z',createUserClient:()=>({rpc:async(name,args)=>{calls.push([name,args]);return {data:name.includes('calendar')?[{event_key:'t24:b'}]:name.includes('missing')?[]:{control:{enabled:true}},error:null}}}),createServiceClient:()=>({rpc:async()=>({data:null,error:null})}),dispatchDueCustomerEmails:async()=>({claimed:0,sent:0,failed:0})});const response=await handler(request('GET'));assert.equal(response.status,200);assert.deepEqual(await response.json(),{dashboard:{control:{enabled:true},recent_runs:[]},events:[{event_key:'t24:b'}]});assert.equal(calls.length,3)});

test('admin history includes missed invocations with impact and recovery evidence',async()=>{
 const {createAdminSchedulerHandler}=await loadHandler();
 const slot={id:'gap-1',expected_at:'2026-09-24T09:00:00Z',detected_at:'2026-09-28T13:15:00Z',resolved_at:'2026-09-24T10:00:00Z',impact_summary:'Processing may have been delayed'};
 const handler=createAdminSchedulerHandler({env,now:()=> '2026-09-28T14:00:00Z',createUserClient:()=>({rpc:async(name)=>({data:name==='v2_site_admin_scheduler_dashboard'?{control:{enabled:true},recent_runs:[]}:name==='v2_site_admin_missing_scheduler_slots'?[slot]:[],error:null})}),createServiceClient:()=>({rpc:async()=>({data:null,error:null})}),dispatchDueCustomerEmails:async()=>({claimed:0,sent:0,failed:0})});
 const response=await handler(request('GET'));
 const run=(await response.json()).dashboard.recent_runs[0];
 assert.equal(run.status,'missed');assert.equal(run.started_at,slot.expected_at);
 assert.equal(run.failure_reason,'No scheduled invocation recorded');
 assert.equal(run.impact_summary,slot.impact_summary);
 assert.match(run.resolution_summary,/2026-09-24T10:00:00Z/);
});

test('enabling immediately runs overdue work as catch up',async()=>{const {createAdminSchedulerHandler}=await loadHandler();const userCalls=[],serviceCalls=[];const handler=createAdminSchedulerHandler({env,now:()=> '2026-09-13T12:00:00Z',createUserClient:()=>({rpc:async(name,args)=>{userCalls.push([name,args]);return {data:{enabled:true,changed:true},error:null}}}),createServiceClient:()=>({rpc:async(name,args)=>{serviceCalls.push([name,args]);if(name==='v2_system_scheduler_begin')return {data:[{run_id:'catch-up',enabled:true}],error:null};return {data:0,error:null}}}),dispatchDueCustomerEmails:async()=>({claimed:1,sent:1,failed:0})});const response=await handler(request('POST',{action:'set_enabled',enabled:true,reason:'Resume'}));assert.equal(response.status,200);assert.equal((await response.json()).catchUp.status,'completed');assert.equal(userCalls[0][0],'v2_site_admin_set_scheduler_enabled');assert.equal(serviceCalls[0][0],'v2_system_scheduler_begin');assert.ok(serviceCalls.findIndex(([name])=>name==='v2_system_reconcile_empty_paired_returns')>serviceCalls.findIndex(([name])=>name==='v2_system_run_scheduled_operations'));assert.equal(serviceCalls.at(-1)[0],'v2_system_scheduler_finish')});

test('manual trigger is booking scoped and records manual provenance',async()=>{const {createAdminSchedulerHandler}=await loadHandler();const calls=[];const handler=createAdminSchedulerHandler({env,now:()=> '2026-09-13T12:00:00Z',createUserClient:()=>({rpc:async(name,args)=>{calls.push([name,args]);return {data:{queued:1,execution_source:'manual'},error:null}}}),createServiceClient:()=>({rpc:async()=>({data:null,error:null})}),dispatchDueCustomerEmails:async()=>({claimed:1,sent:1,failed:0})});const response=await handler(request('POST',{action:'manual_trigger',eventType:'t24',bookingId:'00000000-0000-4000-8000-000000000001'}));assert.equal(response.status,200);assert.deepEqual(calls[0],['v2_site_admin_manual_trigger_scheduled_event',{p_event_type:'t24',p_booking_id:'00000000-0000-4000-8000-000000000001'}]);assert.equal((await response.json()).result.execution_source,'manual')});

test('catch-up records phase progress and keeps partial results when T-24 scheduling fails',async()=>{
 const {createAdminSchedulerHandler}=await loadHandler();const serviceCalls=[];
 const handler=createAdminSchedulerHandler({
  env,now:()=> '2026-09-13T12:00:00Z',
  createUserClient:()=>({rpc:async()=>({data:{enabled:true,changed:false},error:null})}),
  createServiceClient:()=>({rpc:async(name,args)=>{
   serviceCalls.push([name,args]);
   if(name==='v2_system_scheduler_begin')return {data:[{run_id:'catch-up-phases',enabled:true}],error:null};
   if(name==='v2_system_run_scheduled_operations')return {data:{t72_processed:4},error:null};
   if(name==='v2_system_schedule_t24_journey_notifications')return {data:null,error:{message:'T-24 queue unavailable'}};
   return {data:null,error:null};
  }}),
  dispatchDueCustomerEmails:async()=>{throw new Error('email delivery must not run')},
 });

 const response=await handler(request('POST',{action:'run_overdue'}));
 assert.equal(response.status,500);
 assert.deepEqual(serviceCalls.filter(([name])=>name.includes('scheduler_phase')).map(([name,args])=>[name,args.p_phase,args.p_failure_reason||null]),[
  ['v2_system_scheduler_phase_start','journey_operations',null],
  ['v2_system_scheduler_phase_finish','journey_operations',null],
  ['v2_system_scheduler_phase_start','t24_communications',null],
  ['v2_system_scheduler_phase_finish','t24_communications','T-24 queue unavailable'],
 ]);
 assert.deepEqual(serviceCalls.at(-1),['v2_system_scheduler_finish',{
  p_run_id:'catch-up-phases',p_result:{operations:{t72_processed:4,past_empty_returns_cancelled:null}},p_failure_reason:'T-24 queue unavailable',
 }]);
});
