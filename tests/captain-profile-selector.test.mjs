import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const sql=readFileSync(new URL('../supabase/migrations/20260913161202_captain_profile_selector.sql',import.meta.url),'utf8');

test('captain identity lookup returns only active identities owned by the signed-in user',()=>{
 assert.match(sql,/v2_captain_my_identities/i);
 assert.match(sql,/captain[.]auth_user_id\s*=\s*[(]select auth[.]uid[(][)][)]/i);
 assert.match(sql,/captain[.]active/i);
 assert.match(sql,/operator[.]active/i);
});

test('captain identity lookup is authenticated-only',()=>{
 assert.match(sql,/revoke all on function public[.]v2_captain_my_identities[(][)] from public,anon,authenticated/i);
 assert.match(sql,/grant execute on function public[.]v2_captain_my_identities[(][)] to authenticated/i);
});
