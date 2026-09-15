# Partner API and Scheduler Timeout Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the Antigua Boats shuttle feed and hourly Pace V2 scheduler without increasing the production statement timeout.

**Architecture:** Add one forward-only Supabase migration. The partner catalogue returns to the set-based, country-scoped eligibility query that existed before the captain-duty migration regressed it. The scheduler retains operational T-72/T-24 processing but generates at most one missing long-horizon service date per run, allowing backlog recovery without blocking hourly communications.

**Tech Stack:** PostgreSQL/PLpgSQL, Supabase, Node.js contract tests, Next.js/Vercel.

**Spec:** Production failure evidence captured on 2026-09-15: partner RPC times out after scanning 1,563 future departures; scheduler has 172 missing generated departures and its 41-day generation batch exceeds the 8-second statement timeout.

## Global Constraints

- Do not increase the database statement timeout.
- Preserve service-role-only execution of system RPCs.
- Preserve commercial-journey and country-availability filtering.
- Do not create synthetic test journeys.
- Keep T-72, T-24, feedback, and email dispatch behavior unchanged.

---

### Task 1: Add timeout regression contracts

**Files:**
- Create: `tests/production-timeout-regressions.test.mjs`
- Test: `tests/production-timeout-regressions.test.mjs`

**Interfaces:**
- Consumes: the new migration named `supabase/migrations/20260915050000_fix_partner_catalogue_and_scheduler_timeouts.sql`.
- Produces: regression coverage that rejects per-departure catalogue eligibility and multi-day scheduler generation.

- [ ] **Step 1: Write the failing test**

Create two tests. The catalogue test requires country scoping inside `viable`, canonical set-based joins, `d.is_commercial`, and no `get_eligible_vehicle_offers(d.id)`. The scheduler test requires selection of one missing service date and a `generate_departures(v_generation_date,v_generation_date)` call, while preserving the T-72 and T-24 processing loops.

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test tests/production-timeout-regressions.test.mjs`

Expected: FAIL because the forward migration does not exist.

- [ ] **Step 3: Commit the red test with the implementation in Task 2 after it is green**

No test-only commit is required; retain the observed failing output as TDD evidence.

### Task 2: Restore bounded production queries

**Files:**
- Create: `supabase/migrations/20260915050000_fix_partner_catalogue_and_scheduler_timeouts.sql`
- Test: `tests/production-timeout-regressions.test.mjs`

**Interfaces:**
- Produces: `public.v2_system_partner_shuttle_catalog(text)` returning its existing JSON contract, and `public.v2_system_run_scheduled_operations(integer,integer)` returning its existing JSON contract.

- [ ] **Step 1: Restore the catalogue’s set-based query**

Use the canonical joins from `20260830235000_optimize_partner_catalogue_api.sql`, add `d.is_commercial`, retain the active-country pause guard, and scope `r.country_id=v_partner.country_id` before scanning departures.

- [ ] **Step 2: Bound long-horizon generation**

Compute the earliest missing expected service date between `current_date+340` and `current_date+380`. If present, call `pace_v2.generate_departures(v_generation_date,v_generation_date)` only for that date. Then run the existing T-72 and T-24 loops unchanged.

- [ ] **Step 3: Preserve privileges**

Revoke the two system RPCs from `public`, `anon`, and `authenticated`; grant execution only to `service_role`.

- [ ] **Step 4: Run focused and full tests**

Run: `node --test tests/production-timeout-regressions.test.mjs tests/partner-shuttle-api.test.mjs tests/scheduled-operations-route.test.mjs`

Run: `npm test`

Expected: all tests pass.

- [ ] **Step 5: Apply and verify production migration**

Apply the forward migration to Supabase. Under an 8-second local statement timeout, verify the partner catalogue returns authorized tiles with the existing partner key through the live endpoint, and verify one scheduler execution completes and records `status='completed'`.

- [ ] **Step 6: Commit, push, and deploy**

Commit message: `Fix partner catalogue and scheduler timeouts`. Push the branch, merge to `main`, allow the linked Vercel deployment, then scan production errors and re-fetch the Antigua Boats proxy.

