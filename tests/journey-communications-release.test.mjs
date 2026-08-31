import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';

const readRequired = (relativePath) => {
  const url = new URL(`../${relativePath}`, import.meta.url);
  assert.equal(existsSync(url), true, `${relativePath} is missing`);
  return readFileSync(url, 'utf8');
};

test('release security fixture exercises the complete identity and service-role matrix', () => {
  const sql = readRequired('supabase/tests/journey_communications_security_contract.sql');

  assert.match(sql, /^begin;/im);
  assert.match(sql, /^rollback;/im);
  assert.match(sql, /set_config\('request\.jwt\.claim\.sub'/i);
  for (const identity of [
    'owner_a_id',
    'owner_b_id',
    'captain_user_id',
    'other_captain_user_id',
    'operator_user_id',
    'site_admin_user_id',
  ]) assert.match(sql, new RegExp(`\\b${identity}\\b`, 'i'));

  assert.match(sql, /set local role anon/i);
  assert.match(sql, /grant\s+select\s+on\s+journey_communications_security_fixture\s+to\s+anon/i);
  assert.match(sql, /set local role authenticated/i);
  assert.match(sql, /set local role service_role/i);
  assert.match(sql, /v2_customer_my_orders/i);
  assert.match(sql, /v2_customer_my_journey_conversations/i);
  assert.match(sql, /v2_customer_my_journey_messages/i);
  assert.match(sql, /v2_customer_my_feedback/i);
  assert.match(sql, /v2_captain_my_journey_conversations/i);
  assert.match(sql, /v2_captain_my_journey_messages/i);
  assert.match(sql, /v2_admin_journey_conversations/i);
  assert.match(sql, /v2_site_admin_reply_journey_conversation/i);
  assert.match(sql, /v2_customer_submit_feedback/i);
  assert.match(sql, /v2_system_schedule_t24_journey_notifications/i);
  assert.match(sql, /v2_system_schedule_feedback_requests/i);
  assert.match(sql, /v2_system_claim_due_customer_emails_with_metadata/i);
  assert.match(sql, /v2_system_mark_journey_broadcast_email_(?:sent|failed)/i);

  assert.match(sql, /prosecdef/i);
  assert.match(sql, /aclexplode\s*\(/i);
  assert.match(sql, /grantee\s*=\s*0/i);
  assert.match(sql, /has_function_privilege\('anon'/i);
  assert.match(sql, /has_function_privilege\('authenticated'/i);
  assert.match(sql, /has_function_privilege\('service_role'/i);
  assert.match(sql, /relrowsecurity/i);
  assert.match(sql, /security_invoker/i);
});

test('release database scenario proves one deterministic lifecycle for two paid parties', () => {
  const sql = readRequired('supabase/tests/journey_communications_end_to_end.sql');

  assert.match(sql, /^begin;/im);
  assert.match(sql, /^rollback;/im);
  assert.match(sql, /booking_a_id[\s\S]*booking_b_id/i);
  assert.match(sql, /payment_status\s*=\s*'paid'/i);
  assert.match(sql, /status\s*=\s*'cancelled'[\s\S]*not in\s*\(\s*f\.booking_a_id\s*,\s*f\.booking_b_id\s*\)/i);
  assert.match(sql, /v2_system_schedule_t24_journey_notifications/i);
  assert.match(sql, /template_code\s*=\s*'journey_tomorrow'/i);
  assert.match(sql, /v2_customer_open_captain_conversation/i);
  assert.match(sql, /v2_captain_reply_to_party/i);
  assert.match(sql, /v2_captain_broadcast_to_parties/i);
  assert.match(sql, /journey_broadcast_deliveries/i);
  assert.match(sql, /interval\s*'4 hours'\s*-\s*interval\s*'1 microsecond'/i);
  assert.match(sql, /interval\s*'4 hours'/i);
  assert.match(sql, /feedback_due_at/i);
  assert.match(sql, /10:00/i);
  assert.match(sql, /template_code\s*=\s*'post_journey_feedback'/i);
  assert.match(sql, /v2_customer_submit_feedback/i);
  assert.match(sql, /operator_score_effect\s+is\s+not\s+distinct from\s+0\.20/i);
  assert.match(sql, /dimension\s+in\s*\(\s*'pace_shuttles_nps'\s*,\s*'booking_experience'\s*,\s*'pickup'\s*,\s*'destination'\s*\)[\s\S]*operator_score_effect\s*<>\s*0/i);
});

test('scheduled delivery remains protected by the server-only cron boundary', () => {
  const route = readRequired('app/api/operations/run-scheduled/route.ts')
    + readRequired('lib/scheduled-operations-handler.ts');
  const email = readRequired('lib/customer-email.ts');

  assert.match(route, /env:\s*process\.env/);
  assert.match(route, /deps\.env\.CRON_SECRET/);
  assert.match(route, /authorization/);
  assert.match(route, /deps\.env\.SUPABASE_SERVICE_ROLE_KEY/);
  assert.doesNotMatch(route, /NEXT_PUBLIC_SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(route, /v2_system_schedule_t24_journey_notifications/);
  assert.match(route, /v2_system_schedule_feedback_requests/);
  assert.match(route, /deps\.dispatchDueCustomerEmails\(25\)/);
  assert.match(email, /v2_system_claim_due_customer_emails_with_metadata/);
  assert.match(email, /v2_system_mark_journey_broadcast_email_sent/);
  assert.match(email, /v2_system_mark_journey_broadcast_email_failed/);
});
