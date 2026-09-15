import assert from 'node:assert/strict';
import {existsSync, readFileSync} from 'node:fs';
import {test} from 'node:test';

const enumMigrationUrl=new URL('../supabase/migrations/20260915204819_add_closed_unrecorded_status.sql',import.meta.url);
const lifecycleMigrationUrl=new URL('../supabase/migrations/20260915204827_scheduler_history_and_journey_lifecycle.sql',import.meta.url);

function readRequired(url,label){
 assert.ok(existsSync(url),`${label} migration must exist`);
 return readFileSync(url,'utf8');
}

test('Sunday schedule validation uses the same ISO day convention as generation',()=>{
 const sql=readRequired(lifecycleMigrationUrl,'scheduler lifecycle');
 assert.match(sql,/extract\(isodow from new\.local_departure_date\)/i);
 assert.doesNotMatch(sql,/errcode\s*=\s*'40001'/i);
});

test('closed unrecorded status is committed before lifecycle code uses it',()=>{
 const enumSql=readRequired(enumMigrationUrl,'closed-unrecorded enum');
 const lifecycleSql=readRequired(lifecycleMigrationUrl,'scheduler lifecycle');
 assert.match(enumSql,/alter type pace_v2\.departure_status\s+add value if not exists 'closed_unrecorded'/i);
 assert.doesNotMatch(enumSql,/update\s+pace_v2\.departures/i);
 assert.match(lifecycleSql,/'closed_unrecorded'::pace_v2\.departure_status/i);
});

test('T-72 cancels only a journey with no qualifying bookings',()=>{
 const sql=readRequired(lifecycleMigrationUrl,'scheduler lifecycle');
 assert.match(sql,/Cancelled at T-72 — no bookings\./);
 assert.match(sql,/b\.status in\s*\('booked','at_risk','confirmed'\)/i);
 assert.match(sql,/if booking_count=0 then[\s\S]*status='cancelled'/i);
 assert.match(sql,/else[\s\S]*evaluate_t72_booked_parties/i);
});

test('scheduler run phases are durable and service-role only',()=>{
 const sql=readRequired(lifecycleMigrationUrl,'scheduler lifecycle');
 for(const phase of ['journey_operations','t24_communications','feedback_communications','email_delivery'])assert.match(sql,new RegExp(`'${phase}'`));
 assert.match(sql,/create table pace_v2\.scheduler_run_phases/i);
 assert.match(sql,/alter table pace_v2\.scheduler_run_phases enable row level security/i);
 assert.match(sql,/revoke all on pace_v2\.scheduler_run_phases from public,anon,authenticated/i);
 assert.match(sql,/grant execute on function public\.v2_system_scheduler_phase_start\(uuid,text\),[\s\S]*to service_role/i);
 assert.match(sql,/public\.v2_system_scheduler_phase_finish\(uuid,text,jsonb,text\)[\s\S]*to service_role/i);
 assert.doesNotMatch(sql,/grant (?:select|insert|update|delete|all) on pace_v2\.scheduler_run_phases to (?:anon|authenticated)/i);
});

test('bounded past reconciliation never fabricates completion evidence',()=>{
 const sql=readRequired(lifecycleMigrationUrl,'scheduler lifecycle');
 assert.match(sql,/scheduled_arrival_ts[\s\S]*interval '24 hours'/i);
 assert.match(sql,/status='closed_unrecorded'::pace_v2\.departure_status/i);
 assert.match(sql,/closed_count/i);
 assert.doesNotMatch(sql,/insert into pace_v2\.(?:settlements|journey_feedback|customer_feedback)/i);
});

test('dashboard returns recent runs with ordered phase details and resolution evidence',()=>{
 const sql=readRequired(lifecycleMigrationUrl,'scheduler lifecycle');
 assert.match(sql,/'recent_runs'/i);
 assert.match(sql,/scheduler_run_phases/i);
 assert.match(sql,/resolved_by_run_id/i);
 assert.match(sql,/impact_summary/i);
 assert.match(sql,/order by sr\.started_at desc/i);
});
