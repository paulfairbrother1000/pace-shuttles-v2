# Pace V2 Completion and Feedback Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair the completion → feedback → quality → pending-settlement chain without fabricating travel.
**Architecture:** Add forward-only SQL migrations to existing authorized RPCs and internal helpers; retain existing application contracts. Test lifecycle behavior in a disposable database and verify production through read-only evidence after rollout.
**Tech Stack:** PostgreSQL/Supabase, Next.js 15, React 19, Node test runner, Vitest.
**Spec:** `docs/superpowers/specs/2026-10-05-completion-feedback-recovery.md`

## Global Constraints

- Keep whole parties together; preserve existing T-72/T-24 and discount rules.
- Four elapsed hours after actual final completion; no schedule-derived travel.
- Operator rating weight 0.6000; captain rating weight 0.4000; retain configured decay.
- Captain reporting is average /5, count and trend, not a newly invented ranking.
- Settlements remain pending; no automatic approval/payment.
- No production mutating diagnostics, new bookings/journeys or manual message replay.
- Generate migration filenames with `supabase migration new <task-name>`; never rewrite historical migrations.
- Recover dependencies and remaining image assets before claiming a passing full production build.

## Review Focus

1. Multiple boats finishing at different times: no premature pair-wide completion.
2. Retry/concurrent completion or feedback submission: no duplicate accruals, invitations or evidence.
3. Completed/cancelled/refunded outbound bookings: inherit the correct return passenger population.
4. UTC midnight/DST and delayed scheduler execution: elapsed four-hour due time, exactly-once invitation.
5. Missing ledger configuration or unauthorized caller: rollback safely and expose an actionable error.

### Task 1: Paired-return booking population and travel status

**Files:** New CLI-generated migration `paired_return_completion_recovery`; `supabase/tests/paired_return_lifecycle_behavior.sql`; `supabase/tests/captain_duties_and_return_legs_contract.sql`; new `tests/completion-feedback-recovery.test.mjs`.
**Interfaces:** Preserve `public.v2_system_reconcile_empty_paired_returns(p_limit integer) -> integer` and `public.v2_captain_end_leg(p_departure_id uuid,p_completion_state text,p_notes text,p_incident_summary text,p_confirmed_allocation_id uuid) -> timestamptz`.
- [ ] Add failing disposable-DB assertions: outbound completed bookings retain a non-empty return; cancelled/refunded-only bookings do not; zero bookings cancel; return manifest carries identical whole parties without new booking rows.
- [ ] Add assertions: one of two boats finishing cannot complete the pair; the final genuine end completes both legs with their own recorded start/end evidence; identical retries preserve timestamps.
- [ ] Run the fixtures against the current schema and capture the expected failures.
- [ ] Patch current authorized lifecycle functions in a new migration; preserve incident handling, recovery-window checks, selected captain identity and deferred constraint validation.
- [ ] Run positive and unauthorized fixtures, then commit the passing change.

### Task 2: Completion + four-hour feedback timing

**Files:** New CLI-generated migration `feedback_four_hour_due_time`; `supabase/tests/journey_feedback_quality_behavior.sql`; `supabase/tests/journey_feedback_quality_contract.sql`; `tests/journey-communications-sql-structure.test.mjs`.
**Interfaces:** Preserve `pace_v2.feedback_due_at(p_actual_arrival_ts timestamptz,p_timezone text) -> timestamptz` and `public.v2_system_schedule_feedback_requests(p_as_of timestamptz,p_limit integer) -> existing result`.
- [ ] Assert an actual completion at `2026-10-09T17:00:00Z` yields `2026-10-09T21:00:00Z`; no invitation at 20:59:59Z, one at 21:00:00Z.
- [ ] Assert midnight/DST crossing uses four elapsed hours; no completion yields no invitation; a late repeated invocation does not duplicate invitations.
- [ ] Run and confirm current next-day timing fails these tests.
- [ ] Replace due-time calculation and align calendar/display consumers; preserve recipient eligibility and booking-owner checks. Do not reschedule already-sent messages.
- [ ] Run SQL behavior tests and `node --test tests/journey-communications-sql-structure.test.mjs tests/feedback-email-content.test.mjs`, then commit.

### Task 3: Operator score propagation without duplicate evidence

**Files:** New CLI-generated migration `feedback_quality_score_propagation`; `supabase/tests/journey_feedback_quality_behavior.sql`; `supabase/tests/admin_journey_quality_reporting_behavior.sql`; `tests/admin-quality-loaders.test.mjs`.
**Interfaces:** Preserve extended `public.v2_customer_submit_feedback`, `pace_v2.calculate_operator_quality_score(p_operator_id uuid,p_as_of timestamptz)`, `pace_v2.refresh_operator_quality_score(p_operator_id uuid,p_as_of timestamptz) -> numeric` and protected dashboard shape.
- [ ] Assert operator=5/captain=3 contributes `0.6` before decay; operator=3/captain=5 contributes `0.4`; platform NPS alone contributes zero.
- [ ] Assert submitting valid feedback refreshes the operator score in the same transaction; replay cannot add another contribution; legacy feedback remains supported and is not reinterpreted twice.
- [ ] Run tests and record current calculator/refresh failures.
- [ ] Version-gate the legacy evidence trigger; make the calculator consume canonical new `operator_score_effect` with configured decay while retaining non-feedback operational evidence. Refresh after all submission evidence exists, not before it.
- [ ] Test failed/unauthorized submission leaves feedback and scores unchanged. Produce a read-only historical evidence reconciliation report; only apply a separately reviewed data repair.
- [ ] Run SQL and Node tests, then commit.

### Task 4: Verify authoritative captain performance reporting

**Files:** `components/admin-quality-performance.tsx`; `components/admin-quality-performance.test.tsx`; `supabase/tests/admin_journey_quality_reporting_behavior.sql`; `lib/data.ts` only if its existing loader contract requires correction.
**Interfaces:** Preserve `AdminQualityDashboard.captains` entries `id,name,average,response_count,trend`.
- [ ] Assert two captain ratings 4 and 5 display `4.50/5` and count 2; zero responses display no score, not zero; captain metrics remain separate from NPS and operator scores.
- [ ] Verify current production RPC and UI against these assertions; make no change if they already pass.
- [ ] If a contract fails, patch only the authoritative aggregate/loader/display that fails; verify operator/customer cannot read the site-admin report.
- [ ] Run `npx vitest run components/admin-quality-performance.test.tsx` and SQL authorization tests, then commit any necessary fix.

### Task 5: Idempotent pending-settlement accrual

**Files:** New CLI-generated migration `completed_allocation_settlement_accrual`; new `supabase/tests/completion_settlement_behavior.sql`; `tests/completion-feedback-recovery.test.mjs`.
**Interfaces:** Reuse `pace_v2.create_settlement_for_allocation(p_confirmed_allocation_id uuid,p_due_at timestamptz) -> uuid`; preserve `public.v2_admin_create_settlement` and existing financial amounts/statuses.
- [ ] Assert genuine final completion produces one pending settlement and balanced ledger accrual with the confirmed commercial snapshot.
- [ ] Assert repeated/concurrent completion creates one settlement/accrual; an incomplete leg or absent completion produces none; missing ledger accounts rolls back with an actionable error.
- [ ] Confirm current completion path fails the missing-accrual assertion.
- [ ] Hook the existing helper into authorized final completion after actual evidence is persisted; serialize by allocation and enforce idempotency. Retain incident liabilities and pending approval.
- [ ] Run SQL fixtures, including unauthorized calls and two-boat completion, then commit. Do not automatically backfill the previously diagnostic-completed journey.

## Release verification and genuine mobile test

- [ ] Restore npm dependencies from the lockfile and verify the unchanged baseline before running all regression tests.
- [ ] Run `npm test`, `npx tsc --noEmit`, `npm run build`; execute all changed SQL fixtures on a disposable database with the production schema.
- [ ] Review authorization/grants, source changes and migration order; run Supabase security advisors.
- [ ] Apply reviewed migrations, merge reviewed changes and deploy; record exact commit, migration versions and ready production deployment.
- [ ] Read-only checks: hourly phases completed, no relevant runtime errors, due times accurate, no duplicate feedback/accruals.
- [ ] Hand off an existing suitable journey to Paul/captains for genuine mobile start/end of both legs. Verify actual records, pending settlement, automatic invitation on the first scheduler run after +4h, inbox delivery and submitted score propagation. Do not claim live verification until those actions occur.
