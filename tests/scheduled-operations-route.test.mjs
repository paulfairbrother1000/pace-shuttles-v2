import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import ts from 'typescript';

async function loadRoute() {
  const source = readFileSync(new URL('../lib/scheduled-operations-handler.ts', import.meta.url), 'utf8')
    .replace(/^import .*;\s*$/gm, '');
  const nextResponse = `const NextResponse={json:(body,init={})=>new Response(JSON.stringify(body),{status:init.status??200,headers:{'content-type':'application/json'}})};\n`;
  const imports = `const createClient=()=>{throw new Error('production Supabase dependency used in test')};\nconst dispatchDueCustomerEmails=async()=>{throw new Error('production email dependency used in test')};\n`;
  const compiled = ts.transpileModule(nextResponse + imports + source, {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
  }).outputText;
  return import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`);
}

const request = (authorization) => new Request('https://preview.example/api/operations/run-scheduled', {
  headers: authorization ? { authorization } : {},
});

const env = {
  CRON_SECRET: 'scheduled-secret',
  NEXT_PUBLIC_SUPABASE_URL: 'https://example.supabase.co',
  SUPABASE_SERVICE_ROLE_KEY: 'server-role-secret',
};

function dependencies(overrides = {}) {
  return {
    env,
    now: () => '2026-08-31T04:00:00.000Z',
    createClient: () => ({ rpc: async () => ({ data: null, error: null }) }),
    dispatchDueCustomerEmails: async () => ({ claimed: 0, sent: 0, failed: 0 }),
    ...overrides,
  };
}

test('scheduled request rejects a wrong bearer secret before creating privileged dependencies', async () => {
  const { createScheduledOperationsHandler } = await loadRoute();
  assert.equal(typeof createScheduledOperationsHandler, 'function');
  let clientCreations = 0;
  let dispatches = 0;
  const handler = createScheduledOperationsHandler(dependencies({
    createClient: () => { clientCreations += 1; return { rpc: async () => ({ data: null, error: null }) }; },
    dispatchDueCustomerEmails: async () => { dispatches += 1; return { claimed: 0, sent: 0, failed: 0 }; },
  }));

  const response = await handler(request('Bearer wrong-secret'));

  assert.equal(response.status, 401);
  assert.deepEqual(await response.json(), { error: 'Unauthorized' });
  assert.equal(clientCreations, 0);
  assert.equal(dispatches, 0);
});

test('scheduled request completes feedback scheduling before the email claim boundary', async () => {
  const { createScheduledOperationsHandler } = await loadRoute();
  const calls = [];
  const handler = createScheduledOperationsHandler(dependencies({
    createClient: (_url, _key, options) => {
      assert.deepEqual(options, { auth: { persistSession: false } });
      return { rpc: async (name, args) => {
        calls.push([name, args]);
        return name === 'v2_system_run_scheduled_operations'
          ? { data: { departures: 4 }, error: null }
          : { data: 2, error: null };
      } };
    },
    dispatchDueCustomerEmails: async (limit) => {
      calls.push(['claim-and-dispatch', { limit }]);
      return { claimed: 2, sent: 2, failed: 0 };
    },
  }));

  const response = await handler(request('Bearer scheduled-secret'));

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    ok: true,
    result: { departures: 4 },
    emails: { claimed: 2, sent: 2, failed: 0 },
  });
  assert.deepEqual(calls, [
    ['v2_system_run_scheduled_operations', { p_t72_limit: 100, p_t24_limit: 100 }],
    ['v2_system_schedule_t24_journey_notifications', { p_as_of: '2026-08-31T04:00:00.000Z' }],
    ['v2_system_schedule_feedback_requests', { p_as_of: '2026-08-31T04:00:00.000Z', p_limit: 100 }],
    ['claim-and-dispatch', { limit: 25 }],
  ]);
});

test('every scheduler error response stops later work and preserves its database message', async () => {
  const { createScheduledOperationsHandler } = await loadRoute();
  const schedulers = [
    'v2_system_run_scheduled_operations',
    'v2_system_schedule_t24_journey_notifications',
    'v2_system_schedule_feedback_requests',
  ];
  for (const [failureIndex, failingScheduler] of schedulers.entries()) {
    const calls = [];
    let dispatches = 0;
    const handler = createScheduledOperationsHandler(dependencies({
      createClient: () => ({ rpc: async (name) => {
        calls.push(name);
        return name === failingScheduler
          ? { data: null, error: { message: `${failingScheduler} unavailable` } }
          : { data: null, error: null };
      } }),
      dispatchDueCustomerEmails: async () => { dispatches += 1; return { claimed: 0, sent: 0, failed: 0 }; },
    }));

    const response = await handler(request('Bearer scheduled-secret'));

    assert.equal(response.status, 500);
    assert.deepEqual(await response.json(), { error: `${failingScheduler} unavailable` });
    assert.deepEqual(calls, schedulers.slice(0, failureIndex + 1));
    assert.equal(dispatches, 0);
  }
});

test('a thrown scheduling exception propagates without claiming customer email', async () => {
  const { createScheduledOperationsHandler } = await loadRoute();
  let dispatches = 0;
  const handler = createScheduledOperationsHandler(dependencies({
    createClient: () => ({ rpc: async (name) => {
      if (name === 'v2_system_schedule_feedback_requests') throw new Error('feedback transaction aborted');
      return { data: null, error: null };
    } }),
    dispatchDueCustomerEmails: async () => { dispatches += 1; return { claimed: 0, sent: 0, failed: 0 }; },
  }));

  await assert.rejects(() => handler(request('Bearer scheduled-secret')), /feedback transaction aborted/);
  assert.equal(dispatches, 0);
});

test('email claim or dispatch failure returns retryable service-unavailable response', async () => {
  const { createScheduledOperationsHandler } = await loadRoute();
  const handler = createScheduledOperationsHandler(dependencies({
    dispatchDueCustomerEmails: async () => { throw new Error('claim unavailable'); },
  }));

  const response = await handler(request('Bearer scheduled-secret'));

  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: 'Customer email dispatch failed' });
});
