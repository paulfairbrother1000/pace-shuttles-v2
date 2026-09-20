import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const sql=readFileSync(new URL('../supabase/migrations/20260920180000_t24_operator_confirmation_email.sql',import.meta.url),'utf8');

test('T-24 operator email is queued once per operator and outbound journey',()=>{
 assert.match(sql,/T24_OPERATOR_CONFIRMED_EMAIL/i);
 assert.match(sql,/create unique index[\s\S]*operator_id[\s\S]*departure_id[\s\S]*T24_OPERATOR_CONFIRMED_EMAIL/i);
 assert.match(sql,/after insert[\s\S]*on pace_v2\.notifications/i);
 assert.match(sql,/new\.template_code='T24_OPERATOR_CONFIRMED'/i);
 assert.match(sql,/new\.channel='in_app'/i);
});

test('metadata is operator-scoped and contains vehicles, captains, itinerary and party passengers',()=>{
 assert.match(sql,/allocation\.operator_id=p_operator_id/i);
 assert.match(sql,/pace_v2\.captain_assignments/i);
 assert.match(sql,/pace_v2\.passengers/i);
 assert.match(sql,/'age_group'/i);
 assert.match(sql,/'vehicles'/i);
 assert.match(sql,/'itinerary'/i);
 assert.match(sql,/'parties'/i);
 assert.doesNotMatch(sql,/'email'\s*,\s*passenger\.|'phone'\s*,\s*passenger\.|total_price_cents/i);
});

test('missing operational data fails closed and creates a high-priority alert',()=>{
 assert.match(sql,/t24_operator_email_incomplete/i);
 assert.match(sql,/'high'/i);
 assert.match(sql,/cardinality\(v_missing\)>0/i);
 assert.match(sql,/return new/i);
 assert.match(sql,/security definer/i);
 assert.match(sql,/revoke all on function[\s\S]*from public,anon,authenticated/i);
});
