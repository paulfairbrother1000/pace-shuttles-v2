# Service-specific Vehicle Offers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every vehicle offer, its commercial terms, captain preference, and allocation eligibility specific to a recurring route service identified by day and local departure time.

**Architecture:** Add `service_id` to the versioned offer record while retaining `route_id` as validated provenance. Load and save services through the operator editor, label them with a shared schedule formatter, and change departure eligibility from route matching to service matching. Preserve historical snapshots and migrate each existing offer only when its route has one unambiguous service.

**Tech Stack:** PostgreSQL/Supabase migrations and RPCs, Next.js 15, React 19, TypeScript, Node test runner, Vitest/Testing Library.

**Spec:** `docs/superpowers/specs/2026-08-26-service-specific-vehicle-offers-design.md`

## Global Constraints

- Route remains the geographic journey; Service is the recurring day/time offer target.
- Current offers are unique by `(vehicle_id, service_id)` and may coexist for different services on one route.
- Allocation eligibility must match `offer.service_id = departure.service_id`.
- Existing commercial values, captain preferences, historical offers, considerations, and confirmed allocations must remain unchanged.
- The database must derive and validate the service's route rather than trust an inconsistent client pair.
- Existing country/locality, transport-type, operator-access, capacity, discount, and threshold rules remain in force.
- No new anonymous or unrestricted database access is introduced.

---

### Task 1: Service schedule domain and interface behavior

**Files:**
- Modify: `lib/operator-vehicle-editor.ts`
- Modify: `lib/operator-vehicle-editor.test.ts`
- Modify: `components/operator-vehicle-editor.tsx`
- Modify: `components/operator-vehicle-editor.test.tsx`

**Interfaces:**
- Produces: `formatServiceSchedule(daysOfWeek: number[], departureTime: string): string`.
- Produces: `RouteOption` fields `service_id`, `days_of_week`, `departure_time`, and `timezone`.
- Produces: `RouteOfferRow`/`RouteOfferDraft` field `serviceId` and save payload property `service_id`.

- [ ] **Step 1: Write failing domain tests**

Add tests proving that `[6]` and `10:00:00` format as `Saturday at 10:00`, `[2]` and `11:00:00` format as `Tuesday at 11:00`, multiple days retain weekday order, two services on the same route can coexist in a draft, and duplicate service IDs are rejected.

- [ ] **Step 2: Run the domain tests and verify RED**

Run `node_modules/.bin/vitest run lib/operator-vehicle-editor.test.ts` and confirm failure because service identity and formatting do not exist.

- [ ] **Step 3: Implement service identity and formatting**

Extend the types and draft conversion functions so `newRouteOffer` copies `service_id`; validation tracks `serviceId` instead of `routeId`; and `toVehicleSavePayload` emits both `service_id` and `route_id`. Implement weekday mapping using the database convention `1=Monday ... 7=Sunday`, with `0=Sunday` accepted defensively, and normalize `HH:MM:SS` to `HH:MM`.

- [ ] **Step 4: Write failing component tests**

Provide two `RouteOption` fixtures with the same route ID but distinct service IDs and assert that the dropdown and attached cards show `Jolly Harbour → Nobu — Saturday at 10:00` and `Jolly Harbour → Nobu — Tuesday at 11:00` independently.

- [ ] **Step 5: Implement the editor presentation**

Use `service_id` for dropdown values, React keys, attached-set filtering, and add behavior. Render the formatted schedule in both eligible options and offer-card headings without changing the route-specific price, seat, discount, threshold, or captain controls.

- [ ] **Step 6: Verify and commit**

Run both Vitest files, `git diff --check`, then commit `feat: distinguish scheduled services in vehicle editor`.

---

### Task 2: Persist service-specific offers safely

**Files:**
- Create: `supabase/migrations/20260826250000_service_specific_vehicle_offers.sql`
- Create: `tests/service-specific-offers.test.mjs`

**Interfaces:**
- Consumes: editor payload properties `service_id` and `route_id` from Task 1.
- Produces: required `pace_v2.vehicle_route_offers.service_id` foreign key.
- Produces: updated `public.v2_operator_load_vehicle_editor_routes()`, `public.v2_operator_load_vehicle_editor_offers()`, `public.v2_operator_save_vehicle(jsonb)`, and `public.v2_admin_create_route_offer(...)`.

- [ ] **Step 1: Write failing SQL contract tests**

Read the migration source and assert it adds the service foreign key, replaces the `(vehicle_id, route_id)` current-offer index with `(vehicle_id, service_id)`, exposes schedule fields through the editor RPCs, validates service/route consistency, and grants execution only to authenticated callers under existing access checks.

- [ ] **Step 2: Run the contract test and verify RED**

Run `node --test tests/service-specific-offers.test.mjs` and confirm the new migration contract is absent.

- [ ] **Step 3: Implement the schema migration and guarded backfill**

Add nullable `service_id`; abort with an explicit exception if any offer's route maps to zero or multiple services; backfill all historical/current offers; add the foreign key and `NOT NULL`; add a trigger or shared validation function ensuring `service.route_id = offer.route_id`; replace the partial current-offer unique index with `(vehicle_id, service_id) WHERE effective_to IS NULL`.

- [ ] **Step 4: Update editor RPCs and aggregate save**

Return active eligible services joined to their route, vehicle-type and geographic constraints. Return schedule fields on existing offers. In `v2_operator_save_vehicle`, resolve the service row under lock, derive its `route_id`, reject missing/inactive/ineligible services, detect duplicates by vehicle/service, and version an offer when service or commercial fields change.

- [ ] **Step 5: Update the legacy admin creation RPC compatibly**

Replace `v2_admin_create_route_offer` with a service-aware signature containing `p_service_id uuid`; derive its route and apply the same invariant checks. Update `lib/data.ts` and the remaining Site Admin caller in `components/pages.tsx` to select/pass a service rather than choosing the first bare route.

- [ ] **Step 6: Verify and commit**

Run the contract test and existing Node/Vitest tests, then commit `feat: persist vehicle offers by scheduled service`.

---

### Task 3: Match allocation candidates by service

**Files:**
- Modify: `supabase/migrations/20260826250000_service_specific_vehicle_offers.sql`
- Modify: `tests/service-specific-offers.test.mjs`

**Interfaces:**
- Consumes: non-null `vehicle_route_offers.service_id` from Task 2.
- Produces: `pace_v2.get_eligible_vehicle_offers(p_departure_id uuid)` whose primary offer/departure predicate is service equality.
- Preserves: consideration snapshot fields and `vehicle_route_offer_id` provenance.

- [ ] **Step 1: Extend the failing contract test**

Assert the replacement `get_eligible_vehicle_offers` joins offers to the requested departure by `vro.service_id = d.service_id`, retains availability/active/effective-date/capacity rules, and does not admit a route-only alternative.

- [ ] **Step 2: Run the test and verify RED**

Run `node --test tests/service-specific-offers.test.mjs` and confirm failure on the missing service predicate.

- [ ] **Step 3: Replace eligibility matching**

Capture the live function signature and return columns unchanged. Replace only route-level offer eligibility with service-level eligibility so downstream `refresh_vehicle_considerations`, T-72, T-24, pricing, captain assignment, and snapshots continue consuming the same result contract.

- [ ] **Step 4: Add rollback-wrapped behavioral SQL**

Within a transaction, create one route with Saturday and Tuesday services, one vehicle offered only to Saturday, and departures for each service. Assert eligibility includes the vehicle for Saturday and excludes it for Tuesday; then add the Tuesday offer and assert both departures resolve only their own offer. Roll back the transaction.

- [ ] **Step 5: Verify and commit**

Run the SQL contract test and full local suite, then commit `fix: scope allocation eligibility to scheduled service`.

---

### Task 4: Live migration, end-to-end verification, and deployment

**Files:**
- Modify only if verification reveals a defect in the files above.

**Interfaces:**
- Consumes: completed migration and application commits.
- Produces: verified live schema, production commit, and READY deployment.

- [ ] **Step 1: Complete local verification**

Run `git diff --check`, `node --test tests/*.test.mjs`, `node_modules/.bin/vitest run`, and `node_modules/.bin/next build`. Restore any generated `next-env.d.ts` change before committing.

- [ ] **Step 2: Apply the migration to Supabase**

Apply `20260826250000_service_specific_vehicle_offers.sql` through the Supabase migration API. Do not run the DDL as an ad-hoc SQL query.

- [ ] **Step 3: Verify live contracts and behavior**

Query live columns, constraints, indexes, RPC definitions, grants, and the eligibility predicate. Run the rollback-wrapped two-service behavior test. Confirm existing offer counts and commercial/captain values are preserved.

- [ ] **Step 4: Publish to `main`**

Create a fast-forward commit from the current remote `main`, containing the migration, application code, tests, spec, and plan. Update `refs/heads/main` without force.

- [ ] **Step 5: Verify production deployment**

Identify the Vercel production deployment whose Git SHA exactly matches the new `main` commit; poll until `READY`; confirm aliases include `paceshuttles.com` and `www.paceshuttles.com`.

- [ ] **Step 6: Report the operator workflow**

Tell the user that the vehicle editor now lists day/time-specific services, existing offers were preserved, and a vehicle must be added separately to each schedule it will operate.
