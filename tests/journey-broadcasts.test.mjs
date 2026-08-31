import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import ts from 'typescript';

async function loadEmailBuilder() {
  const path = new URL('../lib/journey-broadcast-email.ts', import.meta.url);
  const source = readFileSync(path, 'utf8');
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  return import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`);
}

async function loadDataApi() {
  const path = new URL('../lib/data.ts', import.meta.url);
  const source = readFileSync(path, 'utf8')
    .replace("import { getSupabaseBrowserClient } from './supabase';", "const getSupabaseBrowserClient=()=>({rpc:(name,args)=>({data:{name,args},error:null}),from:()=>({select:()=>({limit:()=>({order:()=>({data:[],error:null})})})})});")
    .replace("import { buildGeographyImagePath, type GeographyKind } from './admin-geography';", "const buildGeographyImagePath=()=>'';");
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  return import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`);
}

test('captain broadcast email identifies route and update category', async () => {
  const { buildJourneyBroadcastEmail } = await loadEmailBuilder();
  const email = buildJourneyBroadcastEmail({
    pickupName: 'Nanny Cay Marina',
    destinationName: 'The Soggy Dollar',
    captainName: 'James Williams',
    category: 'late_running',
    message: 'We are running 15 minutes late.'
  });

  assert.match(email.subject, /Journey update/);
  assert.match(email.subject, /Late running/);
  assert.match(email.text, /Nanny Cay Marina/);
  assert.match(email.text, /The Soggy Dollar/);
  assert.match(email.text, /James Williams/);
  assert.match(email.text, /running 15 minutes late/);
  assert.match(email.text, /My Journeys/);
});

test('captain broadcast API submits only the approved server-side inputs', async () => {
  const { captainBroadcastToParties } = await loadDataApi();
  assert.equal(typeof captainBroadcastToParties, 'function');
  const result = await captainBroadcastToParties('allocation-7', 'We are running 15 minutes late.', 'late_running', 'request-7');
  assert.deepEqual(result.data, {
    name: 'v2_captain_broadcast_to_parties',
    args: {
      p_confirmed_allocation_id: 'allocation-7',
      p_message_text: 'We are running 15 minutes late.',
      p_category: 'late_running',
      p_request_id: 'request-7'
    }
  });
});

test('captain broadcast wrapper requires the caller-owned request id', async () => {
  const { captainBroadcastToParties } = await loadDataApi();
  const result = await captainBroadcastToParties('allocation-7', 'Update', 'operational');
  assert.match(result.error.message, /request id/i);
});

test('a failed submission retains its request id while a changed or completed draft gets a new one', async () => {
  const source = readFileSync(new URL('../lib/journey-broadcast-request.ts', import.meta.url), 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText;
  const { requestIdForBroadcast } = await import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`);
  const ids = ['request-first', 'request-second', 'request-third'];
  const createId = () => ids.shift();
  const first = requestIdForBroadcast('', createId);
  const retryAfterFailure = requestIdForBroadcast(first, createId);
  const changedDraft = requestIdForBroadcast('', createId);
  const nextAfterSuccess = requestIdForBroadcast('', createId);
  assert.equal(retryAfterFailure, first);
  assert.notEqual(changedDraft, first);
  assert.notEqual(nextAfterSuccess, changedDraft);
});

test('changing the selected allocation invalidates a failed draft request id', () => {
  const dashboard = readFileSync(new URL('../components/captain-dashboard.tsx', import.meta.url), 'utf8');
  assert.match(dashboard, /CaptainBroadcastComposer key=\{selected\.confirmed_allocation_id\}/);
});

test('broadcasts fail invalid email recipients before the canonical email claim can process them', () => {
  const migration = readFileSync(new URL('../supabase/migrations/20260830234329_captain_journey_broadcasts.sql', import.meta.url), 'utf8');
  assert.match(migration, /create or replace function pace_v2\.is_valid_customer_notification_email\(p_email text\)/);
  assert.match(migration, /case when pace_v2\.is_valid_customer_notification_email\(v_booking\.to_email\) then 'queued' else 'failed' end/);
  assert.match(migration, /if not pace_v2\.is_valid_customer_notification_email\(v_booking\.to_email\) then/);
  assert.match(migration, /Party leader email is invalid/);
});

test('the metadata claimer validates candidates before its bounded lock and never delegates or post-filters', () => {
  const migration = readFileSync(new URL('../supabase/migrations/20260830234329_captain_journey_broadcasts.sql', import.meta.url), 'utf8');
  const definition = migration.match(/create or replace function public\.v2_system_claim_due_customer_emails_with_metadata\(p_limit integer\)[\s\S]*?\$\$;/i)?.[0];
  assert.ok(definition, 'metadata claim function definition is missing');
  assert.match(definition, /security definer set search_path=public,pace_v2/i);
  assert.doesNotMatch(definition, /public\.v2_system_claim_due_customer_emails\s*\(/i);
  assert.match(definition, /with\s+claim_candidates\s+as\s*\([\s\S]*?from pace_v2\.notifications n[\s\S]*?where[\s\S]*?pace_v2\.is_valid_customer_notification_email\(n\.to_email\)[\s\S]*?order by[\s\S]*?limit[\s\S]*?for update(?: of n)? skip locked[\s\S]*?\),\s*claimed\s+as\s*\(\s*update pace_v2\.notifications/i);
  assert.match(definition, /n\.status in\s*\('queued','failed'\)[\s\S]*?n\.scheduled_at<=now\(\)/i);
  assert.match(definition, /set status='sending',scheduled_at=now\(\)\+interval '5 minutes'/i);
  assert.match(definition, /returning[\s\S]*?n\.metadata/i);
  assert.doesNotMatch(migration, /create or replace function pace_v2\.prevent_invalid_customer_email_claim|create trigger customer_notifications_require_valid_email_before_claim/i);
  assert.match(migration, /revoke all on function [^;]*v2_system_claim_due_customer_emails_with_metadata\(integer\)[^;]* from public,anon,authenticated/i);
  assert.match(migration, /grant execute on function [^;]*v2_system_claim_due_customer_emails_with_metadata\(integer\)[^;]* to service_role/i);
});

test('the executable fixture covers unavailable and malformed emails plus sequential request conflict semantics', () => {
  const fixture = readFileSync(new URL('../supabase/tests/captain_journey_broadcasts_behavior.sql', import.meta.url), 'utf8');
  assert.match(fixture, /update auth\.users u set email='malformed-email'[^;]*owner_b_id/);
  assert.match(fixture, /update auth\.users u set email=null[^;]*owner_c_id/);
  assert.match(fixture, /invalid email notification entered the claimable queue/);
  assert.match(fixture, /invalid email notification did not remain failed and nonclaimable/);
  assert.match(fixture, /invalid email delivery did not record its reason/);
  assert.match(fixture, /invalid email did not create an operational alert/);
  assert.match(fixture, /n\.metadata->>'journey_broadcast_delivery_id'=d\.id::text/);
  assert.match(fixture, /same broadcast request did not return its original source/);
  assert.match(fixture, /different broadcast request did not create a distinct source/);
  assert.match(fixture, /legacy malformed notification changed during claim/);
  assert.match(fixture, /valid due notification was not claimed exactly once/);
  assert.match(fixture, /v2_system_claim_due_customer_emails_with_metadata\(1\)/);
});

test('broadcast migration binds retries to a request id and claims notification metadata', () => {
  const migration = readFileSync(new URL('../supabase/migrations/20260830234329_captain_journey_broadcasts.sql', import.meta.url), 'utf8');
  const fixture = readFileSync(new URL('../supabase/tests/captain_journey_broadcasts_behavior.sql', import.meta.url), 'utf8');
  assert.match(migration, /journey_broadcast_requests/);
  assert.match(migration, /p_request_id uuid/);
  assert.match(migration, /on conflict\(request_id\) do nothing/i);
  assert.match(migration, /v2_system_claim_due_customer_emails_with_metadata/);
  assert.match(migration, /metadata jsonb/);
  assert.match(migration, /v2_system_mark_journey_broadcast_email_sent/);
  assert.match(migration, /v2_system_mark_journey_broadcast_email_failed/);
  assert.match(fixture, /same broadcast request did not return its original source/);
  assert.match(fixture, /broadcast_source_id=f\.source_message_id/);
});
