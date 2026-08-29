# Pace Shuttles Control Centre Deployment Completion Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the current Pace Shuttles Control Centre release is functionally and operationally deployable, correct verified defects, and leave the verified commit active on Vercel production.

**Architecture:** Treat GitHub `main` commit `7781b72` and its READY Vercel production deployment as the baseline. Verify the Next.js application locally, reconcile the committed Supabase migration contracts with the connected V2 project without modifying the legacy V1 project, exercise each role through the deployed application, then deploy only a commit that passes every gate. Database changes, if a verified mismatch requires them, remain forward-only migrations and are applied before promoting the matching application artifact.

**Tech Stack:** Next.js 15, React 19, TypeScript, Node test runner, Vitest, Supabase/Postgres/RLS, Vercel.

**Spec:** `README_SITE_ADMIN_COMPLETION.md`

## Global Constraints

- Always call the business “Pace Shuttles”.
- Preserve customer, operator, captain and Site Admin role separation.
- Do not expose Supabase service-role credentials in the browser.
- Do not apply V2 DDL to the legacy V1 Supabase project.
- Do not activate allocation-engine production behaviour without verified T-72/T-24, payment and rollback evidence.
- A party must remain together on one vehicle; fragmented seats across vehicles cannot satisfy a party.
- Deployment completion requires fresh tests, build, database checks, browser checks and post-deploy error checks.

---

### Task 1: Establish the immutable baseline

**Files:**
- Inspect: `package.json`
- Inspect: `vercel.json`
- Inspect: `supabase/migrations/*.sql`
- Create: `docs/superpowers/plans/2026-08-29-control-centre-deployment.md`

**Interfaces:**
- Consumes: GitHub `main` and Vercel project `pace-shuttles-v2`.
- Produces: Exact commit, deployment and working-tree baseline used by every later gate.

- [ ] **Step 1: Record repository status**

Run: `git status --short --branch && git rev-parse HEAD && git log -5 --oneline`

Expected: clean `main`, HEAD `7781b7261f2fee077ed87509934a4fc222dbee57` before plan creation.

- [ ] **Step 2: Record live deployment**

Query the Vercel project and confirm the production deployment for `7781b72` is `READY`.

- [ ] **Step 3: Commit only if later work creates a deployable change**

Do not create a code commit for inspection alone.

### Task 2: Run the complete local application gate

**Files:**
- Inspect: `package.json`
- Test: `tests/*.test.mjs`
- Test: Vitest-discovered `*.test.ts` and `*.test.tsx`

**Interfaces:**
- Consumes: clean dependency installation from `package-lock.json`.
- Produces: independently recorded test, TypeScript and production-build results.

- [ ] **Step 1: Install pinned dependencies**

Run: `npm ci`

Expected: exit 0 without changing `package-lock.json`.

- [ ] **Step 2: Run the complete test command**

Run: `npm test`

Expected: exit 0 and zero failed Node/Vitest tests.

- [ ] **Step 3: Run TypeScript without emitting files**

Run: `npx tsc --noEmit`

Expected: exit 0 and zero TypeScript diagnostics.

- [ ] **Step 4: Run the production build**

Run: `npm run build`

Expected: exit 0 with all application routes compiled.

### Task 3: Reconcile the Supabase deployment contract

**Files:**
- Inspect: `supabase/migrations/*.sql`
- Test: `supabase/tests/*.sql`
- Inspect: `lib/supabase*.ts`

**Interfaces:**
- Consumes: connected Pace Shuttles V2 Supabase project and committed migration sequence.
- Produces: migration parity, SQL contract results, and database security/advisor evidence.

- [ ] **Step 1: Confirm the connected project identity**

List accessible Supabase projects and match the V2 project ref to the application configuration without displaying keys.

- [ ] **Step 2: Compare migration history**

List remote migration history and compare it with `supabase/migrations`.

Expected: every migration required by `7781b72` is present in order; no V1 project is changed.

- [ ] **Step 3: Run database contract checks**

Execute the read-only assertions in `supabase/tests/*_contract.sql` and the transaction-safe behaviour tests supported by the connected V2 database.

Expected: each assertion returns its documented passing result and behaviour tests roll back their fixtures.

- [ ] **Step 4: Run security and performance advisors**

Query Supabase advisors after migration reconciliation.

Expected: no newly introduced ERROR-level security issue; any pre-existing warning is reported separately.

### Task 4: Verify all four application roles and critical flows

**Files:**
- Inspect: `app/admin/**/*.tsx`
- Inspect: `app/operator/page.tsx`
- Inspect: `app/captain/page.tsx`
- Inspect: `app/customer/page.tsx`
- Inspect: `components/pages.tsx`
- Inspect: `components/ui.tsx`

**Interfaces:**
- Consumes: deployed application, configured E2E identities and reconciled V2 database.
- Produces: route-by-route pass/fail evidence for customer, operator, captain and Site Admin.

- [ ] **Step 1: Verify anonymous and customer access**

Check sign-in routing, booking entry, checkout continuity and `/customer`; confirm privileged routes reject the customer.

- [ ] **Step 2: Verify operator access**

Check `/operator`, scoped fleet/offer editing and absence of Site Admin navigation; confirm unrelated operator data is inaccessible.

- [ ] **Step 3: Verify captain access**

Check `/captain`, assigned journeys, start/stop and voyage-log controls; confirm Site Admin navigation is absent.

- [ ] **Step 4: Verify Site Admin Control Centre**

Check Network, Journeys, Live Operations, Operators, Finance, Support, Analytics and Settings, including Add/Edit Operator and transport-type assignments.

- [ ] **Step 5: Verify operational transitions**

Run the approved synthetic T-72/T-24 workflow in the V2 test context, verify notification/allocation/captain/audit state changes, then run its cleanup and confirm zero residual fixture rows.

### Task 5: Correct only verified deployment blockers

**Files:**
- Modify: exact source or migration file identified by a failing gate.
- Test: matching focused test in `tests/` or `supabase/tests/`.

**Interfaces:**
- Consumes: reproducible failure from Tasks 2–4.
- Produces: regression test that fails before the fix and passes after the minimal fix.

- [ ] **Step 1: Reproduce and isolate each failure**

Run the narrowest existing command that demonstrates the failure and record its exact output.

- [ ] **Step 2: Add a regression assertion**

Add the failing assertion to the nearest existing test file for that route, role or database contract.

- [ ] **Step 3: Prove the assertion fails before implementation**

Run the focused test and confirm the failure describes the verified defect.

- [ ] **Step 4: Implement the smallest safe correction**

Change only the source or forward-only migration needed to satisfy the assertion while preserving the Global Constraints.

- [ ] **Step 5: Re-run focused and complete gates**

Run the focused test, `npm test`, `npx tsc --noEmit`, `npm run build`, relevant SQL contracts and role smoke checks.

- [ ] **Step 6: Commit the verified correction**

Run: `git add <exact changed files> && git commit -m "fix: complete Control Centre deployment verification"`

### Task 6: Deploy and prove the production result

**Files:**
- Deploy: verified Git commit from Task 5, or `7781b72` if no code change is required.

**Interfaces:**
- Consumes: application artifact and database schema that passed all gates.
- Produces: READY production deployment, reachable routes and clean post-deployment error scan.

- [ ] **Step 1: Push the verified commit when a change exists**

Run: `git push origin main`

Expected: remote `main` advances exactly to the locally verified commit.

- [ ] **Step 2: Wait for the matching production deployment**

Confirm Vercel reports `READY`, `target=production` and the exact Git commit SHA.

- [ ] **Step 3: Repeat production smoke checks**

Check the production login/redirect and each role’s landing route using the configured identities.

- [ ] **Step 4: Scan production errors**

Query grouped runtime errors and production logs for the new deployment after the smoke traffic.

Expected: no new application runtime error caused by the release.

- [ ] **Step 5: Publish the deployment result**

Report the URL, target, state, commit, full test counts, database result, role checks, post-deploy error scan, and any explicitly deferred activation item.
