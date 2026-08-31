import assert from 'node:assert/strict';
import {existsSync, readFileSync, readdirSync} from 'node:fs';
import test from 'node:test';
import ts from 'typescript';

const emailModule=new URL('../lib/feedback-email-content.ts',import.meta.url);
const migrationsDir=new URL('../supabase/migrations/',import.meta.url);
const migrationName=readdirSync(migrationsDir).find(name=>name.endsWith('_journey_feedback_quality.sql'));
const migration=migrationName?readFileSync(new URL(`../supabase/migrations/${migrationName}`,import.meta.url),'utf8'):'';
const dataSource=readFileSync(new URL('../lib/data.ts',import.meta.url),'utf8');
const schedulerSource=readFileSync(new URL('../app/api/operations/run-scheduled/route.ts',import.meta.url),'utf8')
  +readFileSync(new URL('../lib/scheduled-operations-handler.ts',import.meta.url),'utf8');

async function loadFeedbackEmail(){
  assert.equal(existsSync(emailModule),true,'feedback email content module is missing');
  const compiled=ts.transpileModule(readFileSync(emailModule,'utf8'),{
    compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}
  }).outputText;
  return import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`);
}

test('feedback email is exactly the approved canonical subject and body',async()=>{
  const {buildFeedbackEmail}=await loadFeedbackEmail();
  const feedbackUrl='https://www.paceshuttles.com/customer?booking=b1&feedback=1';
  const email=buildFeedbackEmail({firstName:'Paul',countryName:'British Virgin Islands',pickupName:'Nanny Cay Marina',destinationName:'The Soggy Dollar',feedbackUrl});
  assert.deepEqual(email,{
   subject:'Thank you for travelling with Pace Shuttles – one more thing…',
   text:'Hi Paul,\n\nThank you for travelling with Pace Shuttles. We hope you had a wonderful journey in British Virgin Islands, travelling from Nanny Cay Marina to The Soggy Dollar.\n\nWe’d really appreciate your feedback about what went well and what we could improve. Your response will help Pace Shuttles, your operator, captain, pickup location and destination continue improving the experience provided to customers.\n\nShare your feedback\nhttps://www.paceshuttles.com/customer?booking=b1&feedback=1\n\nThe survey should take no more than two minutes.\n\nThank you again for choosing Pace Shuttles.\n\nRegards,\nThe Pace Shuttles Team'
  });
});

test('feedback email builder rejects unsafe or non-customer deep links',async()=>{
  const {buildFeedbackEmail}=await loadFeedbackEmail();
  const base={firstName:'Paul',countryName:'Antigua and Barbuda',pickupName:'Harbour',destinationName:'Beach'};
  for(const feedbackUrl of ['javascript:alert(1)','https://evil.example/customer?booking=b1&feedback=1','https://www.paceshuttles.com/customer?booking=b1']){
    assert.throws(()=>buildFeedbackEmail({...base,feedbackUrl}),/feedback url/i);
  }
});

test('journey feedback client submits only the approved ratings, comments and consent',()=>{
  assert.match(dataSource,/export type JourneyFeedbackInput\s*=\s*\{[\s\S]*bookingExperienceRating:number;[\s\S]*nps:number;[\s\S]*operatorRating:number;[\s\S]*captainRating:number;[\s\S]*pickupRating:number;[\s\S]*destinationRating:number;[\s\S]*testimonialConsent:boolean;[\s\S]*\}/);
  assert.match(dataSource,/customerSubmitJourneyFeedback\s*=\s*\(bookingId:string,input:JourneyFeedbackInput\)\s*=>\s*rpc\('v2_customer_submit_feedback',\{p_booking_id:bookingId,p_booking_experience_rating:input\.bookingExperienceRating,p_nps:input\.nps,p_operator_rating:input\.operatorRating,p_captain_rating:input\.captainRating,p_pickup_rating:input\.pickupRating,p_destination_rating:input\.destinationRating,p_went_well:input\.wentWell,p_could_improve:input\.couldImprove,p_testimonial_consent:input\.testimonialConsent\}\)/);
  assert.doesNotMatch(dataSource,/customerSubmitJourneyFeedback[^;]*(?:operator_id|vehicle_id|captain_id|pickup_id|destination_id|attribution)/i);
});

test('feedback migration owns attribution, score separation and local-calendar scheduling',()=>{
  assert.ok(migration,'journey feedback quality migration is missing');
  assert.match(migration,/create or replace function public\.v2_customer_submit_feedback\(p_booking_id uuid,p_booking_experience_rating integer,p_nps integer,p_operator_rating integer,p_captain_rating integer,p_pickup_rating integer,p_destination_rating integer,p_went_well text,p_could_improve text,p_testimonial_consent boolean\)/i);
  assert.doesNotMatch(migration,/v2_customer_submit_feedback\([^)]*p_(?:operator_id|vehicle_id|captain_id|pickup_id|destination_id|attribution)/i);
  assert.match(migration,/pace_v2\.is_active_paid_journey_booking\(p_booking_id,v_user_id\)/i);
  assert.match(migration,/actual_arrival_ts\s+is\s+not\s+null/i);
  assert.match(migration,/p_booking_experience_rating\s+is\s+null[\s\S]*p_nps\s+is\s+null[\s\S]*p_destination_rating\s+is\s+null/i);
  assert.match(migration,/feedback_schema_version[\s\S]*booking_experience_rating is not null[\s\S]*pace_shuttles_nps_score is not null/i);
  assert.match(migration,/operator_rating_weight[\s\S]*0\.60/i);
  assert.match(migration,/captain_rating_weight[\s\S]*0\.40/i);
  assert.match(migration,/operator_rating_effect\s*\*\s*v_operator_weight[\s\S]*captain_rating_effect\s*\*\s*v_captain_weight/i);
  assert.match(migration,/pace_shuttles_nps[\s\S]*operator_score_effect[\s\S]*0/i);
  assert.match(migration,/insert into pace_v2\.quality_evidence\([^)]*evidence_type[^)]*attribution/i);
  assert.match(migration,/'customer_feedback'[\s\S]*'pace_shuttles'/i);
  assert.match(migration,/booking_experience[\s\S]*operator_score_effect[\s\S]*0/i);
  assert.match(migration,/at time zone p_timezone/i);
  assert.match(migration,/case when tz\.name is not null then pace_v2\.feedback_due_at/i);
  assert.match(migration,/post_journey_feedback/i);
  assert.match(migration,/on conflict \(booking_id,template_code\)[\s\S]*do nothing/i);
  assert.match(migration,/limit least\(greatest\(coalesce\(p_limit,0\),0\),500\)/i);
});

test('scheduled operations propagates feedback scheduler failure before email claiming',()=>{
  const feedbackCall=schedulerSource.indexOf('v2_system_schedule_feedback_requests');
  const dispatchCall=schedulerSource.indexOf('deps.dispatchDueCustomerEmails(25)');
  assert.ok(feedbackCall>=0,'feedback scheduler call missing');
  assert.ok(dispatchCall>feedbackCall,'feedback scheduler must run before email claiming and dispatch');
  assert.match(schedulerSource,/feedbackError[\s\S]*status:\s*500/i);
});

test('NPS 0 to 2 opens review evidence without affecting operator quality',()=>{
  assert.match(migration,/if p_nps<=2 then v_low_dimensions:=v_low_dimensions\|\|'"pace_shuttles_nps"'::jsonb/i);
  assert.match(migration,/'pace_shuttles_nps',p_nps,[\s\S]*?,0,1,v_decay/i);
});

test('partial quality history tables are upgraded additively',()=>{
  const required={
    platform_quality_history:['feedback_id','booking_id','dimension','rating','rating_effect','operator_score_effect','occurred_at','created_at'],
    captain_quality_history:['feedback_id','booking_id','departure_id','captain_id','rating','rating_effect','occurred_at','created_at'],
    pickup_quality_history:['feedback_id','booking_id','departure_id','pickup_id','rating','rating_effect','occurred_at','created_at'],
    destination_quality_history:['feedback_id','booking_id','departure_id','destination_id','rating','rating_effect','occurred_at','created_at']
  };
  for(const [table,columns] of Object.entries(required))for(const column of columns){
    assert.match(migration,new RegExp(`alter table pace_v2\\.${table} add column if not exists ${column}\\b`,'i'),`${table}.${column} is not additively upgraded`);
  }
  assert.match(migration,/captain_quality_history_feedback_key[\s\S]*pickup_quality_history_feedback_key[\s\S]*destination_quality_history_feedback_key/i);
});

test('existing feedback consent and schema version nulls are repaired before constraints',()=>{
  assert.match(migration,/update pace_v2\.customer_feedback set testimonial_consent=false where testimonial_consent is null;[\s\S]*alter table pace_v2\.customer_feedback alter column testimonial_consent set default false;[\s\S]*alter table pace_v2\.customer_feedback alter column testimonial_consent set not null/i);
  assert.match(migration,/update pace_v2\.customer_feedback set feedback_schema_version=1 where feedback_schema_version is null;[\s\S]*alter table pace_v2\.customer_feedback alter column feedback_schema_version set default 2;[\s\S]*alter table pace_v2\.customer_feedback alter column feedback_schema_version set not null/i);
  assert.match(migration,/feedback_schema_version<2 or \([\s\S]*destination_rating is not null[\s\S]*\)/i);
  assert.match(migration,/customer_feedback_v2_nps_check[\s\S]*pace_shuttles_nps_score::numeric=trunc\(pace_shuttles_nps_score::numeric\)/i);
});

test('invalid country timezones alert per booking and recover without aborting the scheduler',()=>{
  assert.match(migration,/left join pg_timezone_names tz on tz\.name=c\.timezone/i);
  assert.match(migration,/where tz\.name is null[\s\S]*not exists\(select 1 from pace_v2\.notifications/i);
  assert.match(migration,/feedback_timezone_invalid:/i);
  assert.match(migration,/'feedback_timezone_invalid','high'/i);
  assert.match(migration,/tz\.name is null[\s\S]*on conflict \(exception_key\)/i);
  assert.match(migration,/resolution_note='Country timezone corrected; feedback request will be queued when due'/i);
  assert.match(migration,/update pace_v2\.operational_alerts oa[\s\S]*join pg_timezone_names tz on tz\.name=c\.timezone[\s\S]*oa\.exception_type='feedback_timezone_invalid'/i);
});

test('invalid timezone alerting is independent of the valid due queue limit',()=>{
  const scheduler=migration.slice(migration.indexOf('create or replace function public.v2_system_schedule_feedback_requests'),migration.indexOf('create or replace function public.v2_customer_submit_feedback'));
  const queueLoop=scheduler.slice(scheduler.indexOf('for v_row in'));
  assert.match(scheduler,/insert into pace_v2\.operational_alerts[\s\S]*select distinct on \(b\.id\)[\s\S]*left join pg_timezone_names tz[\s\S]*tz\.name is null[\s\S]*on conflict[\s\S]*for v_row in/i);
  assert.match(queueLoop,/join pg_timezone_names tz on tz\.name=c\.timezone/i);
  assert.doesNotMatch(queueLoop,/left join pg_timezone_names|tz\.name\s+timezone_name|if v_row\.timezone_name/i);
  const limitAt=queueLoop.indexOf('limit least');
  const validTimezoneAt=queueLoop.indexOf('join pg_timezone_names');
  assert.ok(validTimezoneAt>=0&&limitAt>validTimezoneAt,'valid timezone filtering must occur before queue ORDER/LIMIT');

  const behavior=readFileSync(new URL('../supabase/tests/journey_feedback_quality_behavior.sql',import.meta.url),'utf8');
  assert.match(behavior,/feedback_timezone_starvation_fixture/i);
  assert.match(behavior,/earlier_invalid_booking_id[\s\S]*later_valid_booking_id/i);
  assert.match(behavior,/v2_system_schedule_feedback_requests\([^;]*,1\)/i);
  assert.match(behavior,/valid due booking was starved by invalid timezone alert processing/i);
});

test('catalog guards compare exact FK targets, keys, predicates and owned definitions',()=>{
  assert.match(migration,/confkey=array\[v_target_attnum\]::smallint\[\]/i);
  assert.match(migration,/confupdtype='a'[\s\S]*confdeltype='a'[\s\S]*confmatchtype='s'/i);
  assert.match(migration,/foreign key constraint % is owned with an incompatible definition/i);
  assert.match(migration,/indkey::smallint\[\]/i);
  assert.match(migration,/indpred/i);
  assert.match(migration,/indexprs is null/i);
  assert.doesNotMatch(migration,/pg_get_indexdef\(indexrelid\) ~\*/i);
  assert.match(migration,/check constraint % is owned with an incompatible definition/i);

  const contract=readFileSync(new URL('../supabase/tests/journey_feedback_quality_contract.sql',import.meta.url),'utf8');
  assert.match(contract,/confkey=array\[v_target_attnum\]::smallint\[\]/i);
  assert.match(contract,/indpred is null/i);
  assert.match(contract,/indexprs is null/i);
  assert.match(contract,/indkey::smallint\[\]/i);
});

test('unique-index compatibility is catalog-only and compares the complete btree shape',()=>{
  assert.match(migration,/create or replace function pace_v2\._feedback_unique_index_matches/i);
  assert.doesNotMatch(migration,/create\s+(?:unique\s+)?index\s+\w*expected\b/i);
  assert.doesNotMatch(migration,/drop\s+index\s+(?:if\s+exists\s+)?(?:pace_v2\.)?\w*expected\b/i);

  for(const semanticField of [
    /index_class\.relam\s*=\s*v_btree_method/i,
    /candidate\.indclass::oid\[\][\s\S]*=v_expected_opclasses/i,
    /candidate\.indcollation::oid\[\][\s\S]*=v_expected_collations/i,
    /candidate\.indoption::smallint\[\][\s\S]*=v_expected_options/i,
    /candidate\.indnullsnotdistinct\s*=\s*p_nulls_not_distinct/i,
    /candidate\.indimmediate\s*=\s*p_immediate/i,
    /pg_get_expr\(candidate\.indpred,candidate\.indrelid,false\)\s*=\s*p_expected_predicate/i
  ]) assert.match(migration,semanticField);

  assert.match(migration,/p_accept_nonpartial\s+and\s+candidate\.indpred\s+is\s+null/i);
  assert.match(migration,/v_owned_oid[\s\S]*_feedback_unique_index_matches\(v_owned_oid[\s\S]*true\)/i);
  assert.match(migration,/customer_notifications_one_post_journey_feedback_per_booking[\s\S]*_feedback_unique_index_matches\(v_owned_oid[\s\S]*true\)/i);

  const contract=readFileSync(new URL('../supabase/tests/journey_feedback_quality_contract.sql',import.meta.url),'utf8');
  assert.doesNotMatch(contract,/create\s+(?:unique\s+)?index\s+\w*expected\b/i);
  assert.doesNotMatch(contract,/drop\s+index\s+(?:if\s+exists\s+)?(?:pace_v2\.)?\w*expected\b/i);
  assert.match(contract,/indclass::oid\[\][\s\S]*indcollation::oid\[\][\s\S]*indoption::smallint\[\]/i);
  assert.match(contract,/relam/i);
  assert.match(contract,/indnullsnotdistinct/i);
  assert.match(contract,/indimmediate/i);
  assert.match(contract,/feedback_index_guard_probe_wrong_opclass[\s\S]*feedback_index_guard_probe_wrong_collation[\s\S]*feedback_index_guard_probe_wrong_options[\s\S]*feedback_index_guard_probe_wrong_nulls[\s\S]*feedback_index_guard_probe_deferred/i);
  assert.match(contract,/stronger nonpartial unique index was not accepted/i);
});

test('contracts accept exact equivalent checks independently of constraint names',()=>{
  const contract=readFileSync(new URL('../supabase/tests/journey_feedback_quality_contract.sql',import.meta.url),'utf8');
  assert.doesNotMatch(contract,/conname\s*=\s*v_table\|\|'_row_check'/i);
  assert.doesNotMatch(contract,/conname\s*=\s*'customer_feedback_v2_/i);
  assert.match(contract,/pg_get_expr\(c\.conbin,c\.conrelid,false\)\s*=\s*v_expected_check/i);
});

test('SQL fixture selects valid recipients and cleans feedback children before the parent',()=>{
  const behavior=readFileSync(new URL('../supabase/tests/journey_feedback_quality_behavior.sql',import.meta.url),'utf8');
  assert.match(behavior,/join auth\.users u[\s\S]*is_valid_customer_notification_email\(u\.email\)/i);
  assert.match(behavior,/nullif\(trim\(coalesce\(to_jsonb\(b\)->>'customer_name'[\s\S]*is not null/i);
  assert.match(behavior,/join pg_timezone_names tz on tz\.name=c\.timezone/i);
  const evidenceDelete=behavior.indexOf('delete from pace_v2.quality_evidence');
  const feedbackDelete=behavior.indexOf('delete from pace_v2.customer_feedback');
  assert.ok(evidenceDelete>=0&&feedbackDelete>evidenceDelete,'quality evidence must be deleted before customer feedback');
  assert.match(behavior,/p_nps[^\n]*2|,5,2,5,5,5,5,/i);
  assert.match(behavior,/low_dimensions' \? 'pace_shuttles_nps'/i);
});
