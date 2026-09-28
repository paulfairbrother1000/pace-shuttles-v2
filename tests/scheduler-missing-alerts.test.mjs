import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import ts from 'typescript';

async function load(){
 const source=readFileSync(new URL('../lib/scheduler-missing-alerts.ts',import.meta.url),'utf8').replace(/^import .*;\s*$/gm,'');
 const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
 return import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);
}
const row={alert_id:'alert-1',recipient_email:'admin@paceshuttles.com',expected_at:'2026-09-24T09:00:00Z',detected_at:'2026-09-28T13:15:00Z',resolved_at:'2026-09-24T10:00:00Z',impact_summary:'Journey processing and communications may have been delayed.'};
const env={NEXT_PUBLIC_SUPABASE_URL:'https://example.supabase.co',SUPABASE_SERVICE_ROLE_KEY:'service',RESEND_API_KEY:'resend'};

test('missing-slot alert names the exact absent hour and observed recovery',async()=>{
 const {buildMissingSlotAlert}=await load();const mail=buildMissingSlotAlert(row);
 assert.match(mail.subject,/MISSED/);assert.match(mail.text,/2026-09-24T09:00:00Z/);
 assert.match(mail.text,/2026-09-24T10:00:00Z/);assert.match(mail.text,/may have been delayed/);
});

test('delivery uses slot-specific idempotency key and marks the accepted alert sent',async()=>{
 const {dispatchMissingSlotAlerts}=await load();const calls=[];let key;
 const result=await dispatchMissingSlotAlerts(25,{env,createClient:()=>({rpc:async(name,args)=>{calls.push([name,args]);return {data:name==='v2_system_claim_missing_slot_alerts'?[row]:null,error:null}}}),fetchImpl:async(_url,init)=>{key=init.headers['Idempotency-Key'];return {ok:true,json:async()=>({id:'resend-id'})}}});
 assert.deepEqual(result,{claimed:1,sent:1,failed:0});assert.equal(key,'pace-missing-slot-alert-1');
 assert.deepEqual(calls.at(-1),['v2_system_mark_missing_slot_alert_sent',{p_alert_id:'alert-1',p_provider_reference:'resend-id'}]);
});
