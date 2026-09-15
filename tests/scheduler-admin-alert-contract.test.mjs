import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const sql=readFileSync(new URL('../supabase/migrations/20260915221205_scheduler_admin_failure_alerts.sql',import.meta.url),'utf8');

test('scheduler alert deliveries are private, deduplicated and retryable',()=>{
 assert.match(sql,/create table pace_v2\.scheduler_admin_alert_deliveries/i);
 assert.match(sql,/unique\s*\(run_id,alert_type,recipient_email\)/i);
 assert.match(sql,/alter table pace_v2\.scheduler_admin_alert_deliveries enable row level security/i);
 assert.match(sql,/revoke all on pace_v2\.scheduler_admin_alert_deliveries from public,anon,authenticated/i);
 assert.match(sql,/status in\('queued','processing','sent','failed'\)/i);
});

test('finishing a failed run queues one alert per real active Site Admin and a later success queues recovery',()=>{
 assert.match(sql,/from pace_v2\.profiles[\s\S]*join auth\.users/i);
 assert.match(sql,/platform_role='site_admin'/i);
 assert.match(sql,/deleted_at is null/i);
 assert.match(sql,/not like '%@%\.test'/i);
 assert.match(sql,/v_alert_type:='failure'/i);
 assert.match(sql,/v_alert_type:='recovery'/i);
 assert.match(sql,/insert into pace_v2\.scheduler_admin_alert_deliveries[\s\S]*select new\.id,v_alert_type/i);
 assert.match(sql,/on conflict\(run_id,alert_type,recipient_email\) do nothing/i);
});

test('only service role can claim and mark alert deliveries',()=>{
 for(const fn of ['v2_system_claim_scheduler_admin_alerts','v2_system_mark_scheduler_admin_alert_sent','v2_system_mark_scheduler_admin_alert_failed']){
  assert.match(sql,new RegExp(`revoke all on function public\\.${fn}`,'i'));
  assert.match(sql,new RegExp(`grant execute on function public\\.${fn}[\\s\\S]*to service_role`,'i'));
 }
 assert.match(sql,/for update skip locked/i);
});

test('scheduler dashboard reports the next top-of-hour run',()=>{
 assert.match(sql,/next_scheduled_run_at/i);
 assert.match(sql,/date_trunc\('hour',now\(\)\)\+interval '1 hour'/i);
});
