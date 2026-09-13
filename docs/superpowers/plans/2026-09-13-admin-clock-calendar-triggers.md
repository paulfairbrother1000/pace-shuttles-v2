# Site Admin Clock, Calendar & Triggers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an audited Site Admin scheduler control, operational calendar, manual triggers, and evidence that the existing T-24 process runs against the real clock.

**Architecture:** Persist scheduler state and audit/execution records in `pace_v2`, expose only Site Admin RPCs for the browser, and have the existing service-role scheduler endpoint consult and record that state. A dedicated admin page projects normal journeys and notifications into calendar rows; manual actions call a protected server endpoint that reuses the production scheduling and dispatch functions while recording `manual` provenance.

**Tech Stack:** Next.js 15 App Router, React 19, TypeScript, Supabase/PostgreSQL/RLS, Node test runner, Vitest and Testing Library.

**Spec:** `docs/superpowers/specs/2026-09-13-admin-clock-calendar-triggers-design.md`

## Global Constraints

- Use existing regular journeys; do not create, duplicate, or label test journeys.
- Do not introduce a fake or accelerated application clock.
- Keep `public.v2_system_schedule_t24_journey_notifications(timestamptz)` as the T-24 eligibility authority.
- Keep `/api/operations/run-scheduled` as the real scheduler entry point.
- Turning the scheduler on processes overdue work immediately; uniqueness and claim protections must prevent duplicates.
- Do not alter T-24 email copy or replace the external scheduler or email provider.
- Do not deploy or apply Supabase migrations until verification is complete and Paul explicitly approves activation.

---

### Task 1: Persist scheduler state and audit evidence

**Files:**
- Create: `supabase/migrations/20260913120000_admin_scheduler_control.sql`
- Create: `supabase/tests/admin_scheduler_control_contract.sql`
- Create: `supabase/tests/admin_scheduler_control_behavior.sql`
- Test: `tests/admin-scheduler-control.test.mjs`

**Interfaces:**
- Produces: `pace_v2.scheduler_control`, `pace_v2.scheduler_audit`, `pace_v2.scheduler_runs`.
- Produces: `public.v2_system_scheduler_begin(text,timestamptz)`, `public.v2_system_scheduler_finish(uuid,jsonb,text)`, `public.v2_site_admin_scheduler_dashboard()`, and `public.v2_site_admin_set_scheduler_enabled(boolean,text)`.

- [ ] **Step 1: Write failing source-contract tests**

Assert that the migration creates a singleton control row, immutable audit rows, run evidence, Site Admin-only browser RPC grants, service-role-only system grants, and no grants to `anon`.

```js
test('scheduler controls separate Site Admin and service-role authority',()=>{
  assert.match(sql,/create table pace_v2[.]scheduler_control/i);
  assert.match(sql,/v2_site_admin_set_scheduler_enabled/i);
  assert.match(sql,/grant execute[\s\S]+to authenticated/i);
  assert.match(sql,/v2_system_scheduler_begin/i);
  assert.match(sql,/grant execute[\s\S]+to service_role/i);
  assert.doesNotMatch(sql,/grant execute[\s\S]+to anon/i);
});
```

- [ ] **Step 2: Run the contract test and confirm RED**

Run: `node --test tests/admin-scheduler-control.test.mjs`

Expected: failure because the migration does not exist.

- [ ] **Step 3: Implement the migration**

Create a one-row `scheduler_control` table keyed by `control_key='journey_operations'`, defaulting to enabled. Create append-only `scheduler_audit` and `scheduler_runs` tables. `v2_system_scheduler_begin` must atomically insert a run record and return `{run_id, enabled}`; when disabled it records `paused`. `v2_system_scheduler_finish` records `completed` or `failed` plus bounded JSON counters/error text. `v2_site_admin_set_scheduler_enabled` must call the existing Site Admin predicate, lock the singleton row, require a nonblank reason when disabling, update the state, and append old/new state audit evidence. `v2_site_admin_scheduler_dashboard` returns the current state, latest run, and audit history without secrets or message bodies.

- [ ] **Step 4: Add executable SQL behaviour tests**

Cover unauthorized access, Site Admin transitions, no-op transitions, audit actor/timestamps, disabled begin result, enabled begin result, finish evidence, and concurrent-safe singleton locking. Wrap fixtures in a transaction and roll back.

- [ ] **Step 5: Run contract tests and the available SQL fixture harness**

Run: `node --test tests/admin-scheduler-control.test.mjs`

Expected: PASS. Run SQL tests using the repository's established Supabase test command/environment when credentials are present; otherwise record the missing-access blocker and do not infer success.

- [ ] **Step 6: Commit Task 1**

```bash
git add supabase/migrations/20260913120000_admin_scheduler_control.sql supabase/tests/admin_scheduler_control_contract.sql supabase/tests/admin_scheduler_control_behavior.sql tests/admin-scheduler-control.test.mjs
git commit -m "feat: persist scheduler control and audit"
```

### Task 2: Make scheduled execution pause-aware and observable

**Files:**
- Modify: `lib/scheduled-operations-handler.ts`
- Modify: `tests/scheduled-operations-route.test.mjs`

**Interfaces:**
- Consumes: `v2_system_scheduler_begin` and `v2_system_scheduler_finish` from Task 1.
- Produces: scheduler HTTP results `{ok:true,status:'paused'|'completed',runId:string,...}`.

- [ ] **Step 1: Add failing handler tests**

Test that `v2_system_scheduler_begin` is the first RPC, a disabled result returns HTTP 200 with `status:'paused'` and performs no other RPC/email call, successful work finishes the run with counters, and every RPC/dispatch failure records a failed run without leaking secrets.

- [ ] **Step 2: Run the focused test and confirm RED**

Run: `node --test tests/scheduled-operations-route.test.mjs`

Expected: new assertions fail because the begin/finish boundary is absent.

- [ ] **Step 3: Implement pause and run recording**

Refactor the handler to begin the run after secret/environment validation, return immediately when disabled, execute the existing T-72/T-24/feedback/email sequence unchanged when enabled, then finish with the existing result and email counters. In error branches, attempt a failed finish and preserve the current HTTP status semantics.

- [ ] **Step 4: Run focused and communications regressions**

Run: `node --test tests/scheduled-operations-route.test.mjs tests/journey-notification-contract.test.mjs tests/journey-communications-release.test.mjs tests/feedback-email-content.test.mjs`

Expected: PASS.

- [ ] **Step 5: Commit Task 2**

```bash
git add lib/scheduled-operations-handler.ts tests/scheduled-operations-route.test.mjs
git commit -m "feat: pause and audit scheduled operations"
```

### Task 3: Build the Site Admin calendar projection

**Files:**
- Modify: `supabase/migrations/20260913120000_admin_scheduler_control.sql`
- Modify: `supabase/tests/admin_scheduler_control_contract.sql`
- Modify: `supabase/tests/admin_scheduler_control_behavior.sql`
- Modify: `tests/admin-scheduler-control.test.mjs`

**Interfaces:**
- Produces: `public.v2_site_admin_scheduled_event_calendar(p_from timestamptz,p_to timestamptz)` returning `event_key`, `departure_id`, `booking_id`, `route_name`, `event_type`, `due_at`, `journey_timezone`, `execution_source`, `executed_at`, `status`, and `failure_reason`.

- [ ] **Step 1: Add failing projection contract and behaviour tests**

Fixtures must cover pending future T-24, paused due work, overdue due work, processing notification, sent notification, failed notification, post-completion feedback, original due time preservation, and journey timezone.

- [ ] **Step 2: Run tests and confirm RED**

Run: `node --test tests/admin-scheduler-control.test.mjs`

Expected: failure because the calendar RPC is absent.

- [ ] **Step 3: Implement the projection**

Build calendar rows from paid active bookings/departures, confirmed allocation prerequisites, `pace_v2.notifications`, feedback eligibility, scheduler state, and run evidence. Calculate T-24 as `scheduled_departure_ts - interval '24 hours'`; do not use browser time. Return safe failure text only and order by `due_at,event_key`.

- [ ] **Step 4: Run focused and SQL behaviour tests**

Run: `node --test tests/admin-scheduler-control.test.mjs tests/journey-communications-sql-structure.test.mjs`

Expected: PASS plus SQL fixture PASS where database access exists.

- [ ] **Step 5: Commit Task 3**

```bash
git add supabase/migrations/20260913120000_admin_scheduler_control.sql supabase/tests/admin_scheduler_control_contract.sql supabase/tests/admin_scheduler_control_behavior.sql tests/admin-scheduler-control.test.mjs
git commit -m "feat: expose admin scheduling calendar"
```

### Task 4: Add protected scheduler and manual-trigger API actions

**Files:**
- Create: `lib/admin-scheduler-handler.ts`
- Create: `app/api/admin/scheduler/route.ts`
- Create: `tests/admin-scheduler-handler.test.mjs`
- Modify: `lib/customer-email.ts`
- Modify: `tests/customer-email.test.mjs`

**Interfaces:**
- Consumes: authenticated bearer token, Site Admin RPCs, existing system scheduling RPCs, and `dispatchDueCustomerEmails`.
- Produces: `GET` dashboard/calendar, `POST {action:'set_enabled',enabled:boolean,reason:string}`, `POST {action:'run_overdue'}`, and `POST {action:'manual_trigger',eventType:'t24'|'feedback',bookingId:string}`.

- [ ] **Step 1: Write failing API authorization and action tests**

Cover missing token, non-admin token, malformed action, disable confirmation payload, enable-plus-immediate-catch-up, manual provenance, prerequisite failure, idempotent repeat, and safe errors.

- [ ] **Step 2: Run focused tests and confirm RED**

Run: `node --test tests/admin-scheduler-handler.test.mjs tests/customer-email.test.mjs`

Expected: failure because the handler is absent.

- [ ] **Step 3: Implement authenticated Site Admin actions**

Use the caller's JWT with the anon key to verify Site Admin authority through database RPCs. Use a separate service-role client only after authorization for system scheduling/dispatch. Enabling calls the state RPC and then invokes the same scheduling sequence used by the cron handler. Manual trigger passes the selected booking and `manual` source into narrowly scoped database functions; it must not broaden eligibility or modify journey data.

- [ ] **Step 4: Preserve dispatch provenance**

Extend the queued-email metadata/type handling so `execution_source` and original `scheduled_*_at` evidence survive claim, provider dispatch, success, and failure marking without exposing the email body in scheduler logs.

- [ ] **Step 5: Run focused regressions**

Run: `node --test tests/admin-scheduler-handler.test.mjs tests/customer-email.test.mjs tests/scheduled-operations-route.test.mjs`

Expected: PASS.

- [ ] **Step 6: Commit Task 4**

```bash
git add lib/admin-scheduler-handler.ts app/api/admin/scheduler/route.ts tests/admin-scheduler-handler.test.mjs lib/customer-email.ts tests/customer-email.test.mjs
git commit -m "feat: add protected scheduler admin actions"
```

### Task 5: Add the standalone Site Admin page

**Files:**
- Create: `app/admin/clock-calendar/page.tsx`
- Create: `components/admin-clock-calendar.tsx`
- Create: `components/admin-clock-calendar.test.tsx`
- Create: `lib/admin-scheduler.ts`
- Create: `lib/admin-scheduler.test.ts`
- Modify: `components/ui.tsx`
- Modify: `app/globals.css`

**Interfaces:**
- Consumes: Task 4 API responses.
- Produces: responsive `Clock, Calendar & Triggers` Site Admin page.

- [ ] **Step 1: Write failing presentation and interaction tests**

Cover independent navigation, On/Off state, confirmation wording, required disable reason, enable catch-up warning, latest-run counters, timezone-visible rows, all six statuses, safe failure reasons, manual/scheduled badges, action busy states, API failures, and mobile table/card rendering.

- [ ] **Step 2: Run Vitest and confirm RED**

Run: `npx vitest run components/admin-clock-calendar.test.tsx lib/admin-scheduler.test.ts`

Expected: failure because the components/helpers are absent.

- [ ] **Step 3: Implement parsing and status helpers**

In `lib/admin-scheduler.ts`, define typed API payloads and pure functions for status labels, event labels, chronological ordering, and timezone formatting via `Intl.DateTimeFormat` using the returned journey timezone.

- [ ] **Step 4: Implement the page and controls**

Add the `Clock, Calendar & Triggers` navigation entry. Render scheduler state, last run, counters, state-change audit, chronological events, and confirmed actions. After mutations, reload authoritative server data; never optimistically claim a scheduler transition or send succeeded.

- [ ] **Step 5: Add responsive styling**

Use existing card, status, button and mobile conventions. Ensure controls have at least 48px touch targets and calendar content does not cause horizontal page overflow at 390px.

- [ ] **Step 6: Run focused UI tests**

Run: `npx vitest run components/admin-clock-calendar.test.tsx lib/admin-scheduler.test.ts components/auth.test.tsx`

Expected: PASS.

- [ ] **Step 7: Commit Task 5**

```bash
git add app/admin/clock-calendar/page.tsx components/admin-clock-calendar.tsx components/admin-clock-calendar.test.tsx lib/admin-scheduler.ts lib/admin-scheduler.test.ts components/ui.tsx app/globals.css
git commit -m "feat: add admin clock and trigger workspace"
```

### Task 6: Verify the complete feature without production mutation

**Files:**
- Create: `docs/release-evidence/2026-09-13-admin-clock-calendar-triggers.md`
- Modify only if verification exposes a defect: files from Tasks 1-5 and their tests.

**Interfaces:**
- Consumes: completed feature and all repository test suites.
- Produces: reproducible release evidence and an explicit activation gate.

- [ ] **Step 1: Run formatting/static checks**

Run: `git diff --check`

Expected: no errors.

- [ ] **Step 2: Run focused test suites**

Run: `node --test tests/admin-scheduler-control.test.mjs tests/admin-scheduler-handler.test.mjs tests/scheduled-operations-route.test.mjs tests/customer-email.test.mjs tests/journey-notification-contract.test.mjs tests/journey-communications-release.test.mjs tests/feedback-email-content.test.mjs && npx vitest run components/admin-clock-calendar.test.tsx lib/admin-scheduler.test.ts components/auth.test.tsx`

Expected: PASS.

- [ ] **Step 3: Run the full automated suite**

Run: `npm test`

Expected: PASS.

- [ ] **Step 4: Build the production bundle**

Run: `npm run build`

Expected: successful Next.js production build.

- [ ] **Step 5: Rehearse SQL against the production schema inside rollback**

Apply the new migration and execute both scheduler SQL fixtures inside one explicit outer transaction, then `ROLLBACK`. Confirm no schema or data change remains. If credentials are unavailable, report this as a blocker rather than claiming compatibility.

- [ ] **Step 6: Run authenticated browser checks**

Verify Site Admin access, non-admin denial, desktop layout at 1440x900, mobile layout at 390x844, confirmations, failed-action recovery, scheduler pause result, re-enable catch-up, and manual/scheduled provenance. Do not trigger a real customer communication unless the selected existing booking and recipient are approved for the test.

- [ ] **Step 7: Record the real-time T-24 acceptance procedure**

Document a regular journey scheduled slightly more than 24 hours ahead, its confirmed vehicle/captain/customer prerequisites, the calculated T-24 timestamp, expected scheduler cadence, and the evidence fields to capture after crossing T-24. This procedure remains pending until real wall-clock execution occurs.

- [ ] **Step 8: Write evidence and commit**

Record exact commands/results, rollback evidence, browser coverage/blockers, and clearly separate the pending real-time T-24 observation from automated proof.

```bash
git add docs/release-evidence/2026-09-13-admin-clock-calendar-triggers.md
git commit -m "docs: record scheduler control verification"
```

- [ ] **Step 9: Stop at the activation gate**

Do not push, merge, deploy, or apply the migration. Report readiness and request Paul's explicit activation decision.
