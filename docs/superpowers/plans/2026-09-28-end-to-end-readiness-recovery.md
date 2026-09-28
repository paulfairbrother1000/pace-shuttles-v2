# End-to-end Readiness Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore reliable journey closure and allocation evidence, captain sign-in and independent detection of missed hourly runs, then verify the next real journey.

**Architecture:** Retain the existing Supabase scheduler and allocation RPCs, adding narrow forward migrations and contract/behavior tests. Add a separately scheduled authenticated watchdog and expose its missing-slot evidence in the admin history. Keep the established email and in-app channels distinct.

**Tech Stack:** PostgreSQL/Supabase, Next.js 15, TypeScript, Vercel Cron, Node test runner and Vitest.

**Spec:** `docs/superpowers/specs/2026-09-28-end-to-end-readiness-recovery-design.md`

## Global Constraints

- Do not create extra test journeys, split booking parties, reuse a busy vehicle/captain, or change the approved T-72/T-24 policy.
- Do not replay expired itinerary emails or mark unrecorded travel as completed.
- The only email allowed to represent multiple captain identities is `psfairbrother@hotmail.com`.
- The next real test is Jolly Harbour → Boom on 9 October at 10:30 Antigua time; T-72 and T-24 are 6 and 8 October at 10:30 respectively.
- Never place service-role credentials in browser code. Migration functions and watchdog RPCs must be service-role-only; site-admin views must check `is_site_admin()`.

## Review Focus

- A return leg with no paired booking and no recorded arrival closes once, without claiming travel occurred (Task 1).
- A return leg with a booked paired outbound preserves the `closed_unrecorded` outcome (Task 1).
- A missing cron hour generates one alert per admin, while a delayed successful run does not generate a false missed-slot alert (Task 4).
- A second captain identity on a non-test email is rejected, while the approved test mailbox can select all its linked captains (Task 3).
- A journey that cannot meet minimum seats or captain capacity receives a reasoned at-risk result without a fabricated confirmed allocation (Task 2).

---

### Task 1: Reconcile expired paired returns

**Files:** Modify via new `supabase/migrations/<generated>_close_empty_paired_returns.sql`; test `supabase/tests/paired_return_lifecycle_behavior.sql` and `tests/scheduler-history-lifecycle.test.mjs`.

**Interfaces:** Preserve `public.v2_system_run_scheduled_operations(p_t72_limit integer,p_t24_limit integer) returns jsonb`, extending its result with `past_empty_returns_cancelled`. No new public RPC.

- [ ] **Step 1: Write failing tests.** Assert an expired, non-commercial paired return with no qualifying booking on either leg becomes `cancelled` with an explicit empty-return reason after the 24-hour grace period. Assert a booked pair becomes `closed_unrecorded`; terminal and not-yet-due legs do not change; a second run is idempotent.
- [ ] **Step 2: Run tests and verify failure.** Run SQL behavior test using the project's documented Supabase test harness and `node --test tests/scheduler-history-lifecycle.test.mjs`; confirm failure names the missing branch.
- [ ] **Step 3: Generate a migration with `supabase migration new close_empty_paired_returns` and add the narrow branch to the existing scheduler RPC.** Check the live function definition against the latest migration first. Preserve existing logic and grants. Add a one-time reconciliation scoped to the exact twenty currently qualifying IDs by predicate, with audited before/after counts and no booked pair mutations.
- [ ] **Step 4: Run both tests and confirm all lifecycle cases pass; commit migration and tests.**

### Task 2: Diagnose allocation and actual email delivery

**Files:** Inspect `supabase/migrations/20260919170000_recover_early_forced_t24_runs.sql`, `supabase/migrations/20260919230203_captain_duty_reservations.sql`, `supabase/migrations/20260920181750_bind_captain_timing_to_selected_allocation.sql`, `lib/customer-email.ts`, and live `scheduled_job_runs`, `allocation_decisions`, `vehicle_considerations`, `notifications`. Only after reproducing a root cause, add a generated forward migration and a focused test under `supabase/tests/` or `tests/`.

**Interfaces:** Preserve the existing `process_departure_t24(uuid,text,boolean) returns jsonb` and due-email claim RPC; only add a named result field if the observed failure requires one.

- [ ] **Step 1: Trace the 21 and 24 September journeys end-to-end.** Compare actual booking seats, eligible vehicles/captains, T-72/T-24 job outcomes and failure messages, decisions and email-channel notifications against a successful journey. Record a reproducible discrepancy; do not infer a customer email failure from `in_app` pending rows.
- [ ] **Step 2: Write the smallest failing test for the confirmed cause.** Include a no-capacity/no-captain case asserting clear at-risk reasoning, and a valid-capacity case asserting a legal allocation; assert parties remain whole and resources do not overlap.
- [ ] **Step 3: Run targeted test to verify failure; implement one narrow fix in a generated migration or existing source; run target again and confirm pass.** Repeat investigation if the hypothesis fails; do not stack guesses.
- [ ] **Step 4: Check real email-channel due/sent/failed counts and compare scheduler `email_delivery.claimed` against eligible due-email rows.** If there is a discrepancy, reproduce it separately before changing the claim or dispatcher. Do not resend past-travel emails.
- [ ] **Step 5: Run `node --test tests/t72-t24-allocation.test.mjs tests/t24-early-force-recovery.test.mjs tests/journey-communications-release.test.mjs` and the relevant SQL behavior tests; commit each independently proven fix.**

### Task 3: Enable Barefoot captain sign-in

**Files:** Existing `components/captain-dashboard.tsx`, `supabase/migrations/20260913152000_shared_captain_test_login.sql`, `supabase/migrations/20260913161202_captain_profile_selector.sql`; add `tests/captain-signin-readiness.test.mjs` only if changing code. Record the applied captain/user IDs in release evidence without exposing addresses unnecessarily.

**Interfaces:** Reuse `public.v2_admin_link_captain_user(p_captain_id uuid,p_email text) returns uuid` and the existing captain selector. No password or OTP bypass.

- [ ] **Step 1: Inspect both captain IDs, active/operator status and the Auth users with their actual authorized addresses.** Do not invent personal emails. Use the approved shared test mailbox only if both captains are intended as testing identities; otherwise the captain first creates an Auth account using their own mailbox.
- [ ] **Step 2: Verify the existing test for shared-account switching and rejection of shared non-test accounts.** Run `node --test tests/shared-captain-test-login.test.mjs tests/captain-profile-selector.test.mjs` and SQL tests before changing links.
- [ ] **Step 3: Use the site-admin linking RPC for each verified account; read back user/captain/operator mapping and eligibility.** If Auth accounts are absent, leave the link pending and document the exact account-creation action; do not create credentials without an address.
- [ ] **Step 4: Have the mailbox holder complete OTP sign-in and switch through every identity; record actual UI result, not just database mapping.**

### Task 4: Detect missed scheduled runs independently

**Files:** Create `lib/scheduler-watchdog.ts`, `app/api/operations/watch-scheduled/route.ts`, `tests/scheduler-watchdog.test.mjs`, `supabase/tests/scheduler-missed-slots_behavior.sql`, and a generated migration for durable missed slots and admin alert/dashboard access; modify `vercel.json`, `lib/scheduler-history.ts` and the Site Admin clock page if needed.

**Interfaces:** `checkMissedScheduledSlots(now: Date, deps: WatchdogDependencies): Promise<{missing:number;alertsQueued:number;resolved:number}>`; authenticated `GET /api/operations/watch-scheduled` using `CRON_SECRET`; idempotent service-role RPC keyed by expected UTC hourly slot. Since `scheduler_admin_alert_deliveries.run_id` is required, missed-slot alerts need a separate delivery table and claim/mark RPCs or a compatible explicit schema extension, never a fictitious successful scheduler run.

- [ ] **Step 1: Add failing tests for absent scheduled run after a grace interval, late run within grace, duplicate watchdog call, recovery and unauthorized request.** Assert explicit expected hour, impact, resolution and one admin alert per missed slot.
- [ ] **Step 2: Run `node --test tests/scheduler-watchdog.test.mjs` and the SQL behavior test; verify the intended failures.**
- [ ] **Step 3: Generate migration with `supabase migration new scheduler_missed_slot_watchdog`; implement service-role-only slot storage, idempotent detection and an idempotent missed-slot admin alert queue/delivery RPC.** Reuse the existing site-admin recipient policy and Resend dispatch pattern. Expose missed entries beside normal runs in the protected clock history, clearly labeled `Missed — no invocation`.
- [ ] **Step 4: Implement the authenticated route and add a second independent cron in `vercel.json` at minute 15 hourly.** Use a grace period of at least ten minutes and UTC slot keys; watchdog never invokes journey processing. Document common-platform outage limitation.
- [ ] **Step 5: Run target tests, admin UI tests and build; commit.**

### Task 5: Release and genuine 9 October verification

**Files:** `docs/release-evidence/2026-09-28-end-to-end-readiness.md` (create).

**Interfaces:** No new API; production rollout uses the reviewed migrations followed by the matching application commit.

- [ ] **Step 1: Run `npm test` and `npm run build`; run Supabase advisors, review migration grants and compare migration versions.** Record counts, warnings and commit SHA.
- [ ] **Step 2: Apply reviewed forward migrations to project `prvzgvkuefcflvmepuhd`, verify counts/status of old return legs and preserve other journeys.** Do not execute historical customer email dispatch.
- [ ] **Step 3: Deploy matching application to Vercel project `prj_MIH3V4iBLY5lvzEoOIkCCITw5hZ4`; verify READY, production alias, protected watchdog invocation and next real scheduler run.** Check logs and admin clock history.
- [ ] **Step 4: Verify the existing 9 October paid journey at real T-72 (6 October), T-24 (8 October), departure and recorded completion (9 October), then four-hour feedback/NPS/quality.** If minimum four seats is not met, document actual at-risk/cancel behavior and arrange a future existing journey for the completion chain; never backdate or fabricate it.
- [ ] **Step 5: Publish a concise evidence record distinguishing tests, production behavior and phases still awaiting real time.**
