import assert from 'node:assert/strict';
import {existsSync,readFileSync} from 'node:fs';
import test from 'node:test';

const migrationUrl=new URL('../supabase/migrations/20260913120000_admin_scheduler_control.sql',import.meta.url);
const contractUrl=new URL('../supabase/tests/admin_scheduler_control_contract.sql',import.meta.url);
const behaviorUrl=new URL('../supabase/tests/admin_scheduler_control_behavior.sql',import.meta.url);
const read=url=>existsSync(url)?readFileSync(url,'utf8'):'';
const sql=read(migrationUrl),contract=read(contractUrl),behavior=read(behaviorUrl);

test('scheduler control persists singleton state, audits, and runs',()=>{
 assert.match(sql,/create table pace_v2[.]scheduler_control/i);
 assert.match(sql,/control_key text primary key/i);
 assert.match(sql,/check [(]control_key='journey_operations'[)]/i);
 assert.match(sql,/create table pace_v2[.]scheduler_audit/i);
 assert.match(sql,/create table pace_v2[.]scheduler_runs/i);
 assert.match(sql,/insert into pace_v2[.]scheduler_control/i);
});

test('scheduler controls separate Site Admin and service-role authority',()=>{
 assert.match(sql,/v2_site_admin_set_scheduler_enabled/i);
 assert.match(sql,/v2_site_admin_scheduler_dashboard/i);
 assert.match(sql,/if not pace_v2[.]is_site_admin[(][)]/i);
 assert.match(sql,/grant execute on function public[.]v2_site_admin_set_scheduler_enabled[\s\S]+to authenticated/i);
 assert.match(sql,/v2_system_scheduler_begin/i);
 assert.match(sql,/v2_system_scheduler_finish/i);
 assert.match(sql,/grant execute on function public[.]v2_system_scheduler_begin[\s\S]+to service_role/i);
 assert.doesNotMatch(sql,/grant execute[\s\S]+to anon/i);
});

test('scheduler transitions lock state and append actor audit evidence',()=>{
 assert.match(sql,/for update/i);
 assert.match(sql,/auth[.]uid[(][)]/i);
 assert.match(sql,/old_enabled/i);
 assert.match(sql,/new_enabled/i);
 assert.match(sql,/reason/i);
 assert.match(sql,/scheduler_audit/i);
});

test('SQL fixtures exercise role denial, transitions, pause and completion',()=>{
 assert.match(contract,/has_function_privilege[(]'anon'/i);
 assert.match(contract,/has_function_privilege[(]'authenticated'/i);
 assert.match(behavior,/set local role authenticated/i);
 assert.match(behavior,/site admin required/i);
 assert.match(behavior,/scheduler must be paused/i);
 assert.match(behavior,/scheduler must be enabled/i);
 assert.match(behavior,/rollback;/i);
});

test('Site Admin calendar exposes real T-24 and feedback timing with execution provenance',()=>{
 assert.match(sql,/v2_site_admin_scheduled_event_calendar/i);
 assert.match(sql,/scheduled_departure_ts\s*-\s*interval '24 hours'/i);
 assert.match(sql,/post_journey_feedback/i);
 for(const column of ['event_key','departure_id','booking_id','route_name','event_type','due_at','journey_timezone','execution_source','executed_at','status','failure_reason'])assert.match(sql,new RegExp(`\\b${column}\\b`,'i'));
 assert.match(sql,/pace_v2[.]is_site_admin[(][)]/i);
 assert.match(sql,/grant execute on function[\s\S]*public[.]v2_site_admin_scheduled_event_calendar[^;]+to authenticated/i);
 assert.doesNotMatch(sql,/v2_site_admin_scheduled_event_calendar[\s\S]+to anon/i);
});
