import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync} from 'node:fs';

const conversation=readFileSync(new URL('../components/journey-conversation.tsx',import.meta.url),'utf8');
const captain=readFileSync(new URL('../components/captain-dashboard.tsx',import.meta.url),'utf8');
const customer=readFileSync(new URL('../components/pages.tsx',import.meta.url),'utf8');
const customerDay=readFileSync(new URL('../components/customer-day-of-travel.tsx',import.meta.url),'utf8');
const customerSearch=customer.match(/export function CustomerSearch\(\)\s*\{[\s\S]*?(?=\n\s*function ServiceScheduling)/)?.[0]||'';
const readMigration=readFileSync(new URL('../supabase/migrations/20260831011259_journey_message_read_state.sql',import.meta.url),'utf8');

test('journey messaging UI names the captain actions and approved categories',()=>{
 assert.match(conversation,/Contact captain/);
 assert.match(conversation,/Reply to party/);
 assert.match(captain,/Message all parties/);
 for(const category of ['late_running','pickup_change','weather','safety','operational']) assert.match(conversation,new RegExp(`["']${category}["']`));
});

test('journey messaging UI exposes party unread and window state without contact details',()=>{
 assert.match(captain,/Unread/);
 assert.match(captain,/windowState/);
 assert.match(customerSearch,/<CustomerDayOfTravel\s+key=\{selected\.booking_id\}\s+booking=\{selected\}/);
 assert.doesNotMatch(conversation,/\b(email|phone)\b/i);
 assert.doesNotMatch(captain,/\b(email|phone)\b/i);
});

test('the selected My Journeys booking mounts its protected day-of-travel panel',()=>{
 assert.match(customerSearch,/setSelected\(x\)/);
 assert.match(customerSearch,/<CustomerDayOfTravel\s+key=\{selected\.booking_id\}\s+booking=\{selected\}/);
 assert.match(customerDay,/customerOpenCaptainConversation/);
 assert.match(customerDay,/customerSendCaptainMessage/);
});

test('protected database projections own first-contact windows and unread state',()=>{
 assert.match(readMigration,/authorized_customer_booking_message_window/i);
 assert.match(readMigration,/is_active_paid_journey_booking/i);
 assert.match(readMigration,/v2_customer_my_journey_message_windows/i);
 assert.match(readMigration,/journey_message_read_states/i);
 assert.match(readMigration,/v2_mark_journey_conversation_read/i);
 assert.match(readMigration,/unread_count/i);
 assert.doesNotMatch(readMigration,/grant select on pace_v2\.journey_message_read_states to authenticated/i);
});

test('captain messaging derives first broadcast availability from the protected allocation projection',()=>{
 assert.match(readMigration,/authorized_captain_allocation_message_window/i);
 assert.match(readMigration,/v2_captain_my_journey_message_windows/i);
 assert.match(captain,/loadCaptainJourneyMessageWindows/);
});
