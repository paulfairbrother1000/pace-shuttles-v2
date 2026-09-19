import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const sql=readFileSync(new URL('../supabase/migrations/20260919201329_t24_return_itinerary_email.sql',import.meta.url),'utf8');

test('paired T-24 reminders require complete return and passenger data',()=>{
 assert.match(sql,/left join pace_v2\.journey_pairs pair on pair\.outbound_departure_id=d\.id/i);
 assert.match(sql,/return_leg\.scheduled_departure_ts as return_scheduled_departure_ts/i);
 assert.match(sql,/complete return journey schedule/i);
 assert.match(sql,/complete passenger age groups/i);
 assert.match(sql,/adult_count\+v_row\.child_count\+v_row\.infant_count<>v_row\.seats/i);
 assert.match(sql,/operational_alerts[\s\S]*t24_details_overdue/i);
});

test('paired T-24 reminders persist the complete structured itinerary',()=>{
 assert.match(sql,/Reminder of Itinerary for '[|]{2}v_row\.pickup_name[|]{2}' to '[|]{2}v_row\.destination_name[|]{2}' tomorrow/i);
 for(const key of [
  'outbound_pickup_time_label','outbound_arrival_by_time_label',
  'return_pickup_time_label','return_arrival_by_time_label',
  'adult_count','child_count','infant_count','captain_full_name',
  'captain_surname','vehicle_type','vehicle_name','wet_destination'
 ]) assert.match(sql,new RegExp(`'${key}'`,'i'));
 assert.match(sql,/My Journeys > Help & Support > Contact the Captain/i);
 assert.match(sql,/case when v_row\.wet_or_dry='wet'/i);
});

test('captain contact closes at local midnight after the final journey date',()=>{
 const close=sql.match(/create or replace function pace_v2\.journey_message_closes_at[\s\S]*?\n\$\$;/i)?.[0]||'';
 assert.match(close,/coalesce\(return_leg\.local_departure_date,outbound\.local_departure_date\)\+1/i);
 assert.match(close,/at time zone coalesce/i);
 assert.match(close,/return_leg\.trip_timezone/i);
 assert.doesNotMatch(close,/actual_arrival_ts|interval '4 hours'|interval '12 hours'/i);
 assert.match(sql,/revoke all on function pace_v2\.journey_message_closes_at\(uuid\) from public,anon,authenticated/i);
});
