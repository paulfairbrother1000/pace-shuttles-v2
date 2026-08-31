import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync,readdirSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import test from 'node:test';

const migrationsDirectory=fileURLToPath(new URL('../supabase/migrations/',import.meta.url));
const originalMigration=readFileSync(new URL('../supabase/migrations/20260831011259_journey_message_read_state.sql',import.meta.url));

test('the journey read-state migration retains its preview-verified table rename',()=>{
 const checksum=createHash('sha256').update(originalMigration).digest('hex');
 assert.equal(checksum,'08fe5d4c97756afbeb45ac85d7cc1e16d073004b83561e318910c025f3a190b3');
});

test('a forward migration replaces the customer window view with the no-argument RPC',()=>{
 const matches=readdirSync(migrationsDirectory).filter(name=>/^\d{14}_journey_messaging_projection_hardening\.sql$/.test(name));
 assert.equal(matches.length,1,'expected one CLI-generated journey messaging projection hardening migration');
 const migration=readFileSync(`${migrationsDirectory}/${matches[0]}`,'utf8');
 const dropView=migration.search(/drop view public\.v2_customer_my_journey_message_windows/i);
 const createRpc=migration.search(/create or replace function public\.v2_customer_my_journey_message_windows\(\)/i);
 assert.match(migration,/revoke all on (?:table )?public\.v2_customer_my_journey_message_windows from public,anon,authenticated/i);
 assert.ok(dropView>=0&&createRpc>dropView,'the superseded view must be dropped before the RPC is created');
 assert.match(migration,/revoke all on function public\.v2_customer_my_journey_message_windows\(\) from public,anon,authenticated/i);
 assert.match(migration,/grant execute on function public\.v2_customer_my_journey_message_windows\(\) to authenticated/i);
 assert.match(migration,/revoke all on function pace_v2\.authorized_customer_booking_message_window\(uuid\) from public,anon,authenticated/i);
 assert.doesNotMatch(migration,/grant execute on function pace_v2\.authorized_customer_booking_message_window\(uuid\) to authenticated/i);
});
