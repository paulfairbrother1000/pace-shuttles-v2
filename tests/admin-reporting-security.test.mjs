import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
import test from 'node:test';

const dir=new URL('../supabase/migrations/',import.meta.url);
const names=readdirSync(dir).filter(file=>file.endsWith('_admin_journey_quality_reporting.sql')||file.endsWith('_admin_quality_paging_and_compatibility.sql')).sort();
const sql=names.map(name=>readFileSync(new URL(`../supabase/migrations/${name}`,import.meta.url),'utf8')).join('\n');
const forwardName=names.find(name=>name.endsWith('_admin_quality_paging_and_compatibility.sql'));
const forwardSql=forwardName?readFileSync(new URL(`../supabase/migrations/${forwardName}`,import.meta.url),'utf8'):'';
const contract=readFileSync(new URL('../supabase/tests/admin_journey_quality_reporting_contract.sql',import.meta.url),'utf8');
const behavior=readFileSync(new URL('../supabase/tests/admin_journey_quality_reporting_behavior.sql',import.meta.url),'utf8');
const data=readFileSync(new URL('../lib/data.ts',import.meta.url),'utf8');

test('four Site Admin projections have explicit columns and database role enforcement',()=>{
 assert.ok(sql,'additive Site Admin reporting migration is missing');
 for(const view of ['v2_admin_operational_alerts','v2_admin_journey_conversations','v2_admin_journey_messages','v2_admin_journey_broadcast_deliveries']){
  assert.match(sql,new RegExp(`create or replace view public\\.${view}`,'i'));
 }
 assert.match(sql,/where pace_v2\.is_site_admin\(\)/i);
 assert.match(sql,/revoke all on public\.v2_admin_operational_alerts[\s\S]*from public,anon,authenticated/i);
 assert.match(sql,/grant select on public\.v2_admin_operational_alerts[\s\S]*to authenticated/i);
 assert.doesNotMatch(sql,/select\s+\*/i);
});

test('authoritative quality RPCs are protected, uncapped, and preserve source operator scores',()=>{
 assert.match(sql,/v2_site_admin_quality_dashboard\(\)[\s\S]*security definer[\s\S]*pace_v2\.is_site_admin\(\)/i);
 assert.match(sql,/site_admin_operator_quality_source/i);
 assert.doesNotMatch(sql,/limit\s+(?:100|250|500|1000)\b/i);
 assert.match(sql,/v2_site_admin_quality_evidence_page\(p_offset integer,p_limit integer\)/i);
 assert.match(sql,/revoke all on function public\.v2_site_admin_quality_dashboard\(\)[\s\S]*from public,anon,authenticated/i);
 assert.match(sql,/grant execute on function public\.v2_site_admin_quality_dashboard\(\)[\s\S]*to authenticated/i);
 assert.match(sql,/avg\([^)]*\) filter \(where[^)]*is not null\)/i);
 assert.doesNotMatch(sql,/coalesce\([^)]*(?:rating|nps)[^)]*,\s*0\)/i);
});

test('loaders call protected RPCs and retain errors as errors',()=>{
 assert.match(data,/loadAdminQualityDashboard[\s\S]*v2_site_admin_quality_dashboard/i);
 assert.match(data,/loadAdminRecentQualityPage[\s\S]*v2_site_admin_quality_evidence_page/i);
 assert.doesNotMatch(data,/loadAdminQualityDashboard[^;]*error:null/i);
});

test('quality evidence paging keeps nullable legacy targets and returns dimension identities from one count base',()=>{
 assert.ok(names.some(name=>name.endsWith('_admin_quality_paging_and_compatibility.sql')),'forward paging migration is missing');
 assert.match(forwardSql,/select count\(\*\) into v_total from pace_v2\.customer_feedback/i);
 for(const relation of ['operators','captains','pickup_points','destinations'])assert.match(forwardSql,new RegExp(`left join pace_v2\\.${relation}`,'i'));
 for(const field of ['operator_id','operator_name','captain_id','captain_name','pickup_id','pickup_name','destination_id','destination_name'])assert.match(forwardSql,new RegExp(`\\b${field}\\b`,'i'));
 assert.match(forwardSql,/left join\s*\(\s*select qe\.feedback_id,string_agg[\s\S]*group by qe\.feedback_id\s*\) evidence/i);
 assert.match(behavior,/second evidence page/i);
 assert.match(behavior,/nullable legacy target/i);
});

test('Finance loaders preserve predecessor operations views while recent reporting has a dedicated RPC loader',()=>{
 assert.match(data,/loadAdminCustomerFeedback\(\)\{return select\('v2_admin_customer_feedback','created_at',1000\)\}/i);
 assert.match(data,/loadAdminQualityEvidence\(\)\{return select\('v2_admin_quality_evidence','occurred_at',1000\)\}/i);
 assert.match(data,/loadAdminRecentQualityPage/i);
});

test('executable SQL contracts cover columns, admin visibility and anon/customer/operator denial',()=>{
 assert.match(contract,/information_schema\.columns/i);
 assert.match(contract,/has_function_privilege\('anon'/i);
 assert.match(behavior,/set local role authenticated/i);
 assert.match(behavior,/site_admin_user_id/i);
 assert.match(behavior,/customer_user_id/i);
 assert.match(behavior,/operator_user_id/i);
 assert.match(behavior,/anonymous role could/i);
 assert.match(behavior,/legacy null ratings were included/i);
 assert.match(behavior,/customer evidence denial mismatch/i);
 assert.match(behavior,/operator evidence denial mismatch/i);
});
