import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import ts from 'typescript';

async function loadWatchdog(){
 const source=readFileSync(new URL('../lib/scheduler-watchdog.ts',import.meta.url),'utf8').replace(/^import .*;\s*$/gm,'');
 const shim="const NextResponse={json:(body,init={})=>new Response(JSON.stringify(body),{status:init.status??200})};";
 const js=ts.transpileModule(shim+source,{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
 return import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);
}
const env={CRON_SECRET:'secret',NEXT_PUBLIC_SUPABASE_URL:'https://example.supabase.co',SUPABASE_SERVICE_ROLE_KEY:'service'};

test('watchdog refuses unauthenticated requests without touching database or alerts',async()=>{
 const {createSchedulerWatchdogHandler}=await loadWatchdog();let touched=0;
 const handle=createSchedulerWatchdogHandler({env,now:()=> '2026-09-28T13:15:00Z',createClient:()=>{touched++;throw Error('unauthorized access')},dispatchMissingSlotAlerts:async()=>{touched++;return {claimed:0,sent:0,failed:0}}});
 const response=await handle(new Request('https://example.test/api/operations/watch-scheduled'));
 assert.equal(response.status,401);assert.equal(touched,0);
});

test('watchdog checks the last seven days and dispatches durable missed-slot alerts',async()=>{
 const {createSchedulerWatchdogHandler}=await loadWatchdog();const calls=[];
 const handle=createSchedulerWatchdogHandler({env,now:()=> '2026-09-28T13:15:00Z',createClient:()=>({rpc:async(name,args)=>{calls.push([name,args]);return {data:{missing:1,resolved:1,alerts_queued:1},error:null}}}),dispatchMissingSlotAlerts:async()=>{calls.push(['dispatch']);return {claimed:1,sent:1,failed:0}}});
 const response=await handle(new Request('https://example.test/api/operations/watch-scheduled',{headers:{authorization:'Bearer secret'}}));
 assert.equal(response.status,200);
 assert.deepEqual(await response.json(),{ok:true,missing:1,resolved:1,alertsQueued:1,alerts:{claimed:1,sent:1,failed:0}});
 assert.deepEqual(calls,[['v2_system_detect_missing_scheduled_slots',{p_as_of:'2026-09-28T13:15:00Z',p_hours:168}],['dispatch']]);
});

test('watchdog database failure does not claim an alert or claim success',async()=>{
 const {createSchedulerWatchdogHandler}=await loadWatchdog();let dispatches=0;
 const handle=createSchedulerWatchdogHandler({env,now:()=> '2026-09-28T13:15:00Z',createClient:()=>({rpc:async()=>({data:null,error:{message:'database unavailable'}})}),dispatchMissingSlotAlerts:async()=>{dispatches++;return {claimed:0,sent:0,failed:0}}});
 const response=await handle(new Request('https://example.test/api/operations/watch-scheduled',{headers:{authorization:'Bearer secret'}}));
 assert.equal(response.status,503);assert.equal(dispatches,0);
});
