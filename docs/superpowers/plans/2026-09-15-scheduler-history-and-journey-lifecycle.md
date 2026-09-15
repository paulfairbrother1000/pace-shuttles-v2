# Scheduler History and Journey Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the real hourly clock reliable and auditable, cancel truly empty journeys at T-72, preserve booked-journey allocation competition until T-24, and close stale past journeys without misreporting their outcome.

**Architecture:** A forward Supabase migration corrects ISO weekday validation, adds structured scheduler phase evidence, changes only the zero-booking T-72 branch, and adds terminal `closed_unrecorded` reconciliation. The Next.js scheduler handler records durable phase progress around its four existing operations, while the Site Admin clock page renders a plain-language expandable history. Admin journey loaders expose explicit operational and past/closed scopes so historical rows remain accessible without crowding live screens.

**Tech Stack:** PostgreSQL/PLpgSQL on Supabase, Next.js App Router, TypeScript, Supabase JS, Node test runner, Vitest and Testing Library.

**Spec:** `docs/superpowers/specs/2026-09-15-scheduler-history-and-journey-lifecycle-design.md`

## Global Constraints

- The zero-booking cancellation reason is exactly `Cancelled at T-72 — no bookings.`
- Booked journeys retain the current T-72 behavior: discard vehicles with no assigned parties, keep in-play vehicles available for the final 24 hours, and make final assignments at T-24.
- The terminal unverified status is `closed_unrecorded`, displayed as `Closed — travel outcome unrecorded`.
- Scheduler execution/progress functions remain service-role-only; Site Admin history reads remain authenticated and internally check `is_site_admin()`.
- A release is not complete until a real automatic Vercel hourly invocation succeeds in production.

---

### Task 1: Database scheduler and lifecycle repair

**Files:**
- Create: `tests/scheduler-history-lifecycle.test.mjs`
- Create: `supabase/migrations/20260915204819_add_closed_unrecorded_status.sql`
- Create: `supabase/migrations/20260915204827_scheduler_history_and_journey_lifecycle.sql`

**Interfaces:**
- Produces: `public.v2_system_scheduler_phase_start(uuid,text) returns void`
- Produces: `public.v2_system_scheduler_phase_finish(uuid,text,jsonb,text) returns void`
- Produces: `public.v2_site_admin_scheduler_dashboard() returns jsonb` with `latest_run`, `recent_runs`, `control`, and `audit`
- Preserves: `public.v2_system_scheduler_begin(text,timestamptz)` and `public.v2_system_scheduler_finish(uuid,jsonb,text)` signatures
- Preserves: `pace_v2.process_departure_t72(uuid,text,boolean)` booked-party branch

- [ ] **Step 1: Write failing database contract tests**

Add tests that load the forward migration and assert the complete behavioral contract: ISO Sunday validation, no deterministic `40001`, phase evidence protected by service-role grants, exact zero-booking cancellation reason, booked-party delegation retained, `closed_unrecorded` terminal handling, and bounded stale-journey reconciliation.

```js
test('Sunday schedule validation uses the same ISO day convention as generation', () => {
  assert.match(sql, /extract\(isodow from new\.local_departure_date\)/i)
  assert.doesNotMatch(sql, /errcode\s*=\s*'40001'/i)
})

test('T-72 cancels only a journey with no qualifying bookings', () => {
  assert.match(sql, /Cancelled at T-72 — no bookings\./)
  assert.match(sql, /status in \('booked','at_risk','confirmed'\)/i)
  assert.match(sql, /evaluate_t72_booked_parties/i)
})
```

- [ ] **Step 2: Run the new Node test and verify RED**

Run: `node --test tests/scheduler-history-lifecycle.test.mjs`

Expected: FAIL because the forward migration does not exist.

- [ ] **Step 3: Create the forward migration**

Use `supabase migration new` for both files. The first migration adds only the enum value so it commits before any function or data statement uses that value:

```sql
alter type pace_v2.departure_status add value if not exists 'closed_unrecorded';
```

The second migration implements the remaining schema and behavior:

```sql
alter table pace_v2.departures add column if not exists closed_at timestamptz;
alter table pace_v2.departures add column if not exists closure_reason text;
alter table pace_v2.scheduler_runs add column if not exists current_phase text;
alter table pace_v2.scheduler_runs add column if not exists failure_phase text;
alter table pace_v2.scheduler_runs add column if not exists impact_summary text;
alter table pace_v2.scheduler_runs add column if not exists resolved_at timestamptz;
alter table pace_v2.scheduler_runs add column if not exists resolved_by_run_id uuid references pace_v2.scheduler_runs(id);
alter table pace_v2.scheduler_runs add column if not exists resolution_summary text;
```

Create `pace_v2.scheduler_run_phases` keyed by `(run_id, phase)` with phase check values `journey_operations`, `t24_communications`, `feedback_communications`, and `email_delivery`; store start/finish, status, result, and failure reason. Enable RLS, grant no direct client access, and expose writes only through the two service-role functions.

Redefine `guard_service_departure_insert` so both generation and validation use `extract(isodow ...)`; deterministic stale-design validation raises a non-retryable exception.

Redefine `process_departure_t72` so it counts qualifying bookings immediately after obtaining its idempotent job record. If the count is zero, set the departure to `cancelled`, set the exact cancellation reason, cancel/discard considerations, write an allocation decision and complete the job. Otherwise continue through the existing `refresh_vehicle_considerations` and `evaluate_t72_booked_parties` path unchanged.

Redefine `v2_system_run_scheduled_operations` to retain one-date horizon generation, process due T-72/T-24 work, then close past unrecorded journeys in a bounded batch. Use a 24-hour grace period after `scheduled_arrival_ts`, falling back to `scheduled_departure_ts + interval '8 hours'`. Empty open journeys become `cancelled`; booked `confirmed` or `active` journeys without completion evidence become `closed_unrecorded`. Neither branch creates completion, feedback, or settlement evidence.

Update `v2_system_scheduler_finish`: failures preserve partial results and derive the impact from `current_phase`; successful scheduled/catch-up runs resolve older unresolved failures and link them with `resolved_by_run_id`.

Update the Site Admin dashboard RPC to include the latest 100 runs and their ordered phases.

- [ ] **Step 4: Run the database contract test and verify GREEN**

Run: `node --test tests/scheduler-history-lifecycle.test.mjs`

Expected: PASS.

- [ ] **Step 5: Run existing scheduler regression tests**

Run: `node --test tests/production-timeout-regressions.test.mjs tests/scheduled-operations-route.test.mjs tests/admin-scheduler-control.test.mjs`

Expected: PASS with the bounded generation and authorization contracts intact.

- [ ] **Step 6: Commit Task 1**

```bash
git add tests/scheduler-history-lifecycle.test.mjs supabase/migrations/20260915204819_add_closed_unrecorded_status.sql supabase/migrations/20260915204827_scheduler_history_and_journey_lifecycle.sql
git commit -m "Fix scheduler lifecycle and persist run phases"
```

### Task 2: Persist phase evidence in both clock handlers

**Files:**
- Modify: `lib/scheduled-operations-handler.ts`
- Modify: `lib/admin-scheduler-handler.ts`
- Modify: `tests/scheduled-operations-route.test.mjs`
- Modify: `tests/admin-scheduler-handler.test.mjs`

**Interfaces:**
- Consumes: `v2_system_scheduler_phase_start` and `v2_system_scheduler_phase_finish`
- Produces: structured run results with keys `operations`, `t24_queued`, `feedback_queued`, and `emails`

- [ ] **Step 1: Add failing handler tests**

Test the real handler boundary with a stateful fake RPC client. Require ordered phase start/finish calls, partial results retained when a later phase fails, and no execution of later phases after failure.

```js
assert.deepEqual(phaseCalls.map(x => [x.name, x.args.p_phase]), [
  ['v2_system_scheduler_phase_start','journey_operations'],
  ['v2_system_scheduler_phase_finish','journey_operations'],
  ['v2_system_scheduler_phase_start','t24_communications'],
  ['v2_system_scheduler_phase_finish','t24_communications'],
])
assert.equal(finishCall.args.p_result.operations.t72_processed, 2)
```

- [ ] **Step 2: Run focused handler tests and verify RED**

Run: `node --test tests/scheduled-operations-route.test.mjs tests/admin-scheduler-handler.test.mjs`

Expected: FAIL because phase RPCs and partial failure results are absent.

- [ ] **Step 3: Add one phase runner to each dependency-injected handler**

For each phase, persist start, run the existing operation, persist completed result, and store the partial result in memory. On error, persist the failed phase and call `v2_system_scheduler_finish` with the partial result rather than `{}`. Keep the existing authorization boundary and stop later work after any failed phase.

- [ ] **Step 4: Run focused handler tests and verify GREEN**

Run: `node --test tests/scheduled-operations-route.test.mjs tests/admin-scheduler-handler.test.mjs`

Expected: PASS.

- [ ] **Step 5: Commit Task 2**

```bash
git add lib/scheduled-operations-handler.ts lib/admin-scheduler-handler.ts tests/scheduled-operations-route.test.mjs tests/admin-scheduler-handler.test.mjs
git commit -m "Record durable scheduler phase progress"
```

### Task 3: Add readable execution history to Site Admin

**Files:**
- Modify: `lib/admin-scheduler.ts`
- Create: `lib/scheduler-history.ts`
- Create: `lib/scheduler-history.test.ts`
- Modify: `components/admin-clock-calendar.tsx`
- Modify: `components/admin-clock-calendar.test.tsx`

**Interfaces:**
- Consumes: `dashboard.recent_runs[]` and nested `phases[]`
- Produces: `schedulerRunDuration(run)`, `schedulerRunImpact(run)`, and `schedulerRunResolution(run)` presentation helpers

- [ ] **Step 1: Write failing helper and component tests**

Use literal run fixtures. Assert failed and successful rows, source, local timestamps, duration, expanded ordered phases, counts, impact, unresolved state, and later resolution. Assert raw JSON is never rendered.

```tsx
expect(screen.getByText('Journey operations')).toBeTruthy()
expect(screen.getByText(/No T-72 or T-24 lifecycle changes committed/)).toBeTruthy()
expect(screen.getByText(/Resolved by successful scheduled run/)).toBeTruthy()
expect(screen.queryByText(/\{"operations"/)).toBeNull()
```

- [ ] **Step 2: Run focused Vitest and verify RED**

Run: `npx vitest run lib/scheduler-history.test.ts components/admin-clock-calendar.test.tsx`

Expected: FAIL because the history helpers and execution list do not exist.

- [ ] **Step 3: Implement typed history helpers and expandable UI**

Keep Latest execution at the top. Add Execution history below it with newest first. Each row shows status, source, requested time, duration, summary counts, and impact/resolution. A `Show details` button expands named phase rows with timestamps, status, result counts, and failure reason.

- [ ] **Step 4: Run focused Vitest and verify GREEN**

Run: `npx vitest run lib/scheduler-history.test.ts components/admin-clock-calendar.test.tsx`

Expected: PASS.

- [ ] **Step 5: Commit Task 3**

```bash
git add lib/admin-scheduler.ts lib/scheduler-history.ts lib/scheduler-history.test.ts components/admin-clock-calendar.tsx components/admin-clock-calendar.test.tsx
git commit -m "Add scheduler execution history drill-down"
```

### Task 4: Separate operational journeys from past/closed history

**Files:**
- Modify: `lib/data.ts`
- Create: `lib/journey-scope.ts`
- Create: `lib/journey-scope.test.ts`
- Modify: `components/dashboard.tsx`
- Modify: corresponding component tests or create `components/live-operations.test.tsx`

**Interfaces:**
- Produces: `loadAdminJourneys(scope?: 'operational'|'past_closed')`
- Produces: `journeyScopeLabel(scope)` and terminal status classification

- [ ] **Step 1: Write failing scope and UI tests**

Assert the default loader requests only nonterminal current/future rows, Past/closed requests terminal historical rows newest first, and Live Operations exposes an explicit `Past / closed` scope while defaulting to `Operational`.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `npx vitest run lib/journey-scope.test.ts components/live-operations.test.tsx`

Expected: FAIL because scoped loaders and controls do not exist.

- [ ] **Step 3: Implement scoped Supabase queries and UI**

Operational scope excludes `completed`, `cancelled`, and `closed_unrecorded` and omits journeys beyond the stale grace window. Past/closed scope includes terminal statuses and orders newest first. Dashboard uses operational scope. Live Operations reloads when its scope selector changes and resets incompatible status filters.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `npx vitest run lib/journey-scope.test.ts components/live-operations.test.tsx`

Expected: PASS.

- [ ] **Step 5: Commit Task 4**

```bash
git add lib/data.ts lib/journey-scope.ts lib/journey-scope.test.ts components/dashboard.tsx components/live-operations.test.tsx
git commit -m "Separate live journeys from closed history"
```

### Task 5: Full verification and production release

**Files:**
- Verify all files changed by Tasks 1-4

- [ ] **Step 1: Run full automated verification**

Run: `npm test`

Expected: all Node and Vitest suites pass.

Run: `npm run build`

Expected: production build exits 0.

- [ ] **Step 2: Validate the migration transactionally against production shape**

In a rolled-back transaction, install the changed functions and prove Sunday generation accepts ISO day `7`, a zero-booking T-72 journey cancels, a booked T-72 journey still uses the booked-party branch, and stale closure does not create settlement or feedback evidence.

- [ ] **Step 3: Run Supabase advisors**

Review security and performance findings. Confirm this migration introduces no public grants, exposed tables, or unprotected `SECURITY DEFINER` execution.

- [ ] **Step 4: Publish and merge the verified branch**

Push `fix/scheduler-history-lifecycle`, create a PR, review the diff, and merge only the verified commits.

- [ ] **Step 5: Apply the production migration and verify reconciliation**

Apply `20260915204819_add_closed_unrecorded_status.sql` followed by `20260915204827_scheduler_history_and_journey_lifecycle.sql`. Confirm the eleven affected future zero-booking journeys are cancelled with the exact T-72 reason, the two past booked unrecorded journeys are `closed_unrecorded`, and no open past journey remains.

- [ ] **Step 6: Verify the production deployment and Site Admin API**

Confirm Vercel production is READY, `/api/admin/scheduler` serves recent runs with phase detail to Site Admin, operational screens exclude past/closed rows by default, and no new runtime errors appear.

- [ ] **Step 7: Observe a real automatic hourly run**

Wait for the next `0 * * * *` invocation. Confirm `execution_source='scheduled'`, `status='completed'`, all four phases completed, Sunday generation no longer retries, and any prior unresolved failure links to the successful run.
