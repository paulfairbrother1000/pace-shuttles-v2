import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import ts from 'typescript';

async function loadDispatcher() {
  const path = new URL('../lib/customer-email.ts', import.meta.url);
  const builderPath = new URL('../lib/journey-broadcast-email.ts', import.meta.url);
  const feedbackBuilderPath = new URL('../lib/feedback-email-content.ts', import.meta.url);
  const builder = ts.transpileModule(readFileSync(builderPath, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 }
  }).outputText.replaceAll('export ', '');
  const feedbackBuilder = ts.transpileModule(readFileSync(feedbackBuilderPath, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 }
  }).outputText.replaceAll('export ', '');
  const source = readFileSync(path, 'utf8')
    .replace("import {createClient} from '@supabase/supabase-js';", '')
    .replace("import {buildJourneyBroadcastEmail,type JourneyBroadcastCategory} from './journey-broadcast-email';", builder)
    .replace("import {buildFeedbackEmail} from './feedback-email-content';", feedbackBuilder);
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  return import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`);
}

const row = { notification_id: 'notification-42', to_email: 'paul@example.com', subject: 'Tomorrow', body: 'Body', template_code: 'journey_tomorrow', booking_id: 'booking-1', departure_id: 'departure-1' };
const env = { NEXT_PUBLIC_SUPABASE_URL: 'https://example.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'server-secret', RESEND_API_KEY: 'resend-secret' };

test('accepted Resend retries use the same notification-derived idempotency key', async () => {
  const { dispatchDueCustomerEmails } = await loadDispatcher();
  const keys = [];
  const client = { rpc: async (name) => {
    if (name === 'v2_system_claim_due_customer_emails_with_metadata') return { data: [row], error: null };
    if (name === 'v2_system_mark_email_sent') return { error: { message: 'temporary mark failure' } };
    return { error: null };
  } };
  const fetchImpl = async (_url, request) => {
    keys.push(request.headers['Idempotency-Key']);
    return { ok: true, json: async () => ({ id: 'resend-accepted' }) };
  };
  const deps = { env, createClient: () => client, fetchImpl };
  await dispatchDueCustomerEmails(1, deps);
  await dispatchDueCustomerEmails(1, deps);
  assert.deepEqual(keys, ['pace-notification-notification-42', 'pace-notification-notification-42']);
});

test('configuration and claim failures reject for a scheduler retry while delivery failures remain recorded per message', async () => {
  const { dispatchDueCustomerEmails } = await loadDispatcher();
  await assert.rejects(() => dispatchDueCustomerEmails(1, { env: {}, createClient: () => null, fetchImpl: async () => null }), /not configured/);
  await assert.rejects(() => dispatchDueCustomerEmails(1, { env, createClient: () => ({ rpc: async () => ({ data: null, error: { message: 'claim unavailable' } }) }), fetchImpl: async () => null }), /claim unavailable/);
  const marked = [];
  const result = await dispatchDueCustomerEmails(1, {
    env,
    createClient: () => ({ rpc: async (name) => name === 'v2_system_claim_due_customer_emails_with_metadata' ? { data: [row], error: null } : (marked.push(name), { error: null }) }),
    fetchImpl: async () => ({ ok: false, json: async () => ({ message: 'provider unavailable' }), status: 503 })
  });
  assert.deepEqual(result, { claimed: 1, sent: 0, failed: 1 });
  assert.deepEqual(marked, ['v2_system_mark_email_failed']);
});

test('a journey broadcast provider failure preserves its notification and marks the private delivery retryable', async () => {
  const { dispatchDueCustomerEmails } = await loadDispatcher();
  const marked = [];
  const journeyBroadcast = {
    ...row,
    notification_id: 'notification-broadcast-42',
    template_code: 'journey_broadcast',
    metadata: { journey_broadcast_delivery_id: 'delivery-42', pickup_name: 'Nanny Cay Marina', destination_name: 'The Soggy Dollar', captain_name: 'James Williams', category: 'late_running', message: 'We are running late.' }
  };
  const result = await dispatchDueCustomerEmails(1, {
    env,
    createClient: () => ({ rpc: async (name) => name === 'v2_system_claim_due_customer_emails_with_metadata' ? { data: [journeyBroadcast], error: null } : (marked.push(name), { error: null }) }),
    fetchImpl: async () => ({ ok: false, json: async () => ({ message: 'provider unavailable' }), status: 503 })
  });
  assert.deepEqual(result, { claimed: 1, sent: 0, failed: 1 });
  assert.deepEqual(marked, ['v2_system_mark_journey_broadcast_email_failed']);
});

test('an accepted broadcast email is not counted sent until the atomic notification and delivery transition succeeds', async () => {
  const { dispatchDueCustomerEmails } = await loadDispatcher();
  const calls = [];
  let outbound;
  const journeyBroadcast = {
    ...row,
    notification_id: 'notification-broadcast-transition-42',
    template_code: 'journey_broadcast',
    metadata: { journey_broadcast_delivery_id: 'delivery-transition-42', pickup_name: 'Nanny Cay Marina', destination_name: 'The Soggy Dollar', captain_name: 'James Williams', category: 'late_running', message: 'We are running late.' }
  };
  const result = await dispatchDueCustomerEmails(1, {
    env,
    createClient: () => ({ rpc: async (name) => {
      calls.push(name);
      if (name === 'v2_system_claim_due_customer_emails_with_metadata') return { data: [journeyBroadcast], error: null };
      if (name === 'v2_system_mark_journey_broadcast_email_sent') return { error: { message: 'transition unavailable' } };
      return { error: null };
    } }),
    fetchImpl: async (_url, request) => { outbound=JSON.parse(request.body); return { ok: true, json: async () => ({ id: 'resend-accepted' }) }; }
  });
  assert.deepEqual(result, { claimed: 1, sent: 0, failed: 1 });
  assert.deepEqual(calls, [
    'v2_system_claim_due_customer_emails_with_metadata',
    'v2_system_mark_journey_broadcast_email_sent',
    'v2_system_mark_journey_broadcast_email_failed'
  ]);
  assert.equal(outbound.subject, 'Journey update: Late running');
  assert.match(outbound.text, /Nanny Cay Marina to The Soggy Dollar/);
});

test('blank claimed broadcast recipients are failed without calling the provider', async () => {
  const { dispatchDueCustomerEmails } = await loadDispatcher();
  const calls = [];
  const result = await dispatchDueCustomerEmails(1, {
    env,
    createClient: () => ({ rpc: async (name) => {
      calls.push(name);
      if (name === 'v2_system_claim_due_customer_emails_with_metadata') return { data: [{ ...row, to_email: ' ', template_code: 'journey_broadcast', metadata: { journey_broadcast_delivery_id: 'delivery-empty' } }], error: null };
      return { error: null };
    } }),
    fetchImpl: async () => { throw new Error('provider must not be called'); }
  });
  assert.deepEqual(result, { claimed: 1, sent: 0, failed: 1 });
  assert.deepEqual(calls, ['v2_system_claim_due_customer_emails_with_metadata', 'v2_system_mark_journey_broadcast_email_failed']);
});

test('malformed claimed broadcast recipients are failed without calling the provider', async () => {
  const { dispatchDueCustomerEmails } = await loadDispatcher();
  const calls = [];
  let providerCalls = 0;
  const result = await dispatchDueCustomerEmails(1, {
    env,
    createClient: () => ({ rpc: async (name) => {
      calls.push(name);
      if (name === 'v2_system_claim_due_customer_emails_with_metadata') return { data: [{ ...row, to_email: 'malformed-email', template_code: 'journey_broadcast', metadata: { journey_broadcast_delivery_id: 'delivery-malformed', pickup_name: 'Nanny Cay Marina', destination_name: 'The Soggy Dollar', captain_name: 'James Williams', category: 'late_running', message: 'We are running late.' } }], error: null };
      return { error: null };
    } }),
    fetchImpl: async () => { providerCalls++; throw new Error('provider must not be called'); }
  });
  assert.deepEqual(result, { claimed: 1, sent: 0, failed: 1 });
  assert.equal(providerCalls, 0);
  assert.deepEqual(calls, ['v2_system_claim_due_customer_emails_with_metadata', 'v2_system_mark_journey_broadcast_email_failed']);
});

test('post-journey feedback dispatch uses the canonical builder and first-name metadata', async () => {
  const { dispatchDueCustomerEmails } = await loadDispatcher();
  let outbound;
  const feedbackRow={...row,template_code:'post_journey_feedback',metadata:{first_name:'Paul',country_name:'British Virgin Islands',pickup_name:'Nanny Cay Marina',destination_name:'The Soggy Dollar',feedback_url:'https://www.paceshuttles.com/customer?booking=booking-1&feedback=1'}};
  await dispatchDueCustomerEmails(1,{
   env,
   createClient:()=>({rpc:async name=>name==='v2_system_claim_due_customer_emails_with_metadata'?{data:[feedbackRow],error:null}:{error:null}}),
   fetchImpl:async(_url,request)=>{outbound=JSON.parse(request.body);return {ok:true,json:async()=>({id:'feedback-email-1'})};}
  });
  assert.equal(outbound.subject,'Thank you for travelling with Pace Shuttles – one more thing…');
  assert.equal(outbound.text,'Hi Paul,\n\nThank you for travelling with Pace Shuttles. We hope you had a wonderful journey in British Virgin Islands, travelling from Nanny Cay Marina to The Soggy Dollar.\n\nWe’d really appreciate your feedback about what went well and what we could improve. Your response will help Pace Shuttles, your operator, captain, pickup location and destination continue improving the experience provided to customers.\n\nShare your feedback\nhttps://www.paceshuttles.com/customer?booking=booking-1&feedback=1\n\nThe survey should take no more than two minutes.\n\nThank you again for choosing Pace Shuttles.\n\nRegards,\nThe Pace Shuttles Team');
});
