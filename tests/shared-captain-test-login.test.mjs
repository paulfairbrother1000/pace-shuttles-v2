import assert from 'node:assert/strict';
import {existsSync,readFileSync} from 'node:fs';
import test from 'node:test';

const migrationUrl=new URL('../supabase/migrations/20260913152000_shared_captain_test_login.sql',import.meta.url);
const behaviorUrl=new URL('../supabase/tests/shared_captain_test_login_behavior.sql',import.meta.url);
const read=url=>existsSync(url)?readFileSync(url,'utf8'):'';
const sql=read(migrationUrl),behavior=read(behaviorUrl);

test('only the approved test login may represent multiple captains',()=>{
 assert.match(sql,/drop index(?:\s+if exists)?\s+pace_v2[.]ux_captains_auth_user/i);
 assert.match(sql,/psfairbrother@hotmail[.]com/i);
 assert.match(sql,/captain login is already linked to another captain/i);
 assert.match(sql,/create constraint trigger\s+captains_guard_shared_test_login/i);
});

test('Site Admin captain linking retains explicit authorization and safe grants',()=>{
 assert.match(sql,/v2_admin_link_captain_user/i);
 assert.match(sql,/if not pace_v2[.]is_site_admin[(][)]/i);
 assert.match(sql,/revoke all on function public[.]v2_admin_link_captain_user/i);
 assert.match(sql,/grant execute on function public[.]v2_admin_link_captain_user[^;]+to authenticated/i);
 assert.doesNotMatch(sql,/grant execute[^;]+to anon/i);
});

test('behavior fixture proves shared test access and rejects ordinary shared access',()=>{
 assert.match(behavior,/psfairbrother@hotmail[.]com/i);
 assert.match(behavior,/ordinary-shared-captain@example[.]test/i);
 assert.match(behavior,/expected ordinary shared captain login rejection/i);
 assert.match(behavior,/rollback;/i);
});
