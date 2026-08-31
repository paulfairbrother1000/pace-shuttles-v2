import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
import test from 'node:test';

const data=readFileSync(new URL('../lib/data.ts',import.meta.url),'utf8');

test('client exposes the private journey messaging RPC contracts',()=>{
  assert.match(data,/export const customerOpenCaptainConversation=\(bookingId:string,message:string\)=>\s*rpc\('v2_customer_open_captain_conversation',\{p_booking_id:bookingId,p_message_text:message\}\)/);
  assert.match(data,/export const customerSendCaptainMessage=\(conversationId:string,message:string\)=>\s*rpc\('v2_customer_send_captain_message',\{p_conversation_id:conversationId,p_message_text:message\}\)/);
  assert.match(data,/export const captainReplyToParty=\(conversationId:string,message:string,category:string\)=>\s*rpc\('v2_captain_reply_to_party',\{p_conversation_id:conversationId,p_message_text:message,p_category:category\}\)/);
});

test('private messaging enforces paid active bookings and security-invoker reads',()=>{
  const migrationName=readdirSync(new URL('../supabase/migrations/',import.meta.url))
    .find(name=>name.endsWith('_private_journey_messaging.sql'));
  assert.ok(migrationName,'private journey messaging migration is missing');
  const sql=readFileSync(new URL(`../supabase/migrations/${migrationName}`,import.meta.url),'utf8');
  assert.match(sql,/is_active_paid_journey_booking/i);
  assert.match(sql,/join pace_v2\.orders o on o\.id=b\.order_id/i);
  assert.match(sql,/payment_status.*paid.*succeeded.*complete.*completed/is);
  assert.match(sql,/status.*cancelled.*canceled.*refunded.*inactive/is);
  assert.match(sql,/security_invoker\s*=\s*true/i);
  assert.match(sql,/create policy journey_conversations_private_read/i);
  assert.match(sql,/create policy journey_messages_private_read/i);
  assert.match(sql,/closed_at=null/i);
});

test('security-invoker reads grant only the columns they expose',()=>{
  const migrationName=readdirSync(new URL('../supabase/migrations/',import.meta.url))
    .find(name=>name.endsWith('_private_journey_messaging.sql'));
  const sql=readFileSync(new URL(`../supabase/migrations/${migrationName}`,import.meta.url),'utf8');
  assert.match(sql,/grant select \(id,booking_id,confirmed_allocation_id,status,opened_at,closed_at,created_at\)\s+on pace_v2\.journey_conversations to authenticated/i);
  assert.match(sql,/grant select \(id,conversation_id,sender_type,category,message_text,broadcast_source_id,created_at\)\s+on pace_v2\.journey_conversation_messages to authenticated/i);
  assert.doesNotMatch(sql,/grant select on pace_v2\.journey_conversations,pace_v2\.journey_conversation_messages to authenticated/i);
});

test('views project message timing only through an authorised conversation helper',()=>{
  const migrationName=readdirSync(new URL('../supabase/migrations/',import.meta.url))
    .find(name=>name.endsWith('_private_journey_messaging.sql'));
  const sql=readFileSync(new URL(`../supabase/migrations/${migrationName}`,import.meta.url),'utf8');
  assert.match(sql,/authorized_journey_message_window/i);
  assert.match(sql,/can_access_journey_conversation\(p_conversation_id,p_audience\)/i);
  assert.match(sql,/grant execute on function[\s\S]*pace_v2\.authorized_journey_message_window\(uuid,text\)[\s\S]*to authenticated/i);
});
