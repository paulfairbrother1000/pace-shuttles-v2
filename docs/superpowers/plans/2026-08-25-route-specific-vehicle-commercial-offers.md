# Route-Specific Vehicle Commercial Offers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make vehicle commercial economics route-specific so each operator independently sets minimum whole-journey revenue and seat economics for each vehicle/route combination.

**Architecture:** Keep vehicles as physical/operational records and make `vehicle + route` Route Offers the authoritative commercial input to allocation. Preserve existing route-offer data and allocation snapshots, remove route-independent pricing from vehicle creation UX, validate route/vehicle compatibility and capacity, and keep historical confirmed journeys immune from later offer edits.

**Tech Stack:** Next.js 15, React 19, TypeScript, Supabase/PostgreSQL RPCs/views/RLS, Node test runner.

**Spec:** `docs/superpowers/specs/2026-08-25-route-specific-vehicle-commercial-offers-design.md`

## Global Constraints

- Pace Shuttles route is directional; opposite directions are different routes.
- A scheduled journey comprises two operational legs.
- `minimum journey revenue` is for the complete two-leg journey.
- Operators manually choose commercial values; Pace Shuttles does not calculate operator cost.
- One current active offer per `vehicle + route`.
- Route Offer edits affect future allocation calculations only; confirmed financial snapshots are immutable.
- `max_seats` cannot exceed physical vehicle capacity.
- Existing Route Offers must not be silently repriced.

---

## File structure

- `supabase/migrations/20260825_route_specific_vehicle_commercial_offers.sql` — database constraints, protected RPCs/views and compatibility enforcement for route-specific offers.
- `lib/data.ts` — typed client wrappers for revised vehicle creation and Route Offer create/update functions.
- `components/operator-dashboard.tsx` — operator Route Offer UX/copy/validation; Fleet remains operational only.
- `components/pages.tsx` — Site Admin Operator Detail Fleet and Route Offers separation; explicit offer creation rather than copying vehicle defaults.
- `tests/route-offer-commercial-model.test.mjs` — static regression tests guarding route-specific semantics and preventing vehicle-level pricing UX from returning.
- `tests/route-offer-allocation-contract.test.mjs` — regression checks for the SQL/RPC contract and snapshot/uniqueness/capacity rules.

### Task 1: Lock the route-specific commercial contract with failing regression tests

**Files:**
- Create: `tests/route-offer-commercial-model.test.mjs`
- Create: `tests/route-offer-allocation-contract.test.mjs`

**Interfaces:**
- Consumes: current `components/pages.tsx`, `components/operator-dashboard.tsx`, `lib/data.ts`, migration SQL.
- Produces: executable assertions defining the approved commercial boundary.

- [ ] **Step 1: Write the failing UI/model regression test**

Use Node's built-in test/assert modules. Read `components/pages.tsx` and `components/operator-dashboard.tsx` as text and assert:

```js
assert.doesNotMatch(adminPages, /Minimum journey revenue \(USD\).*adminCreateVehicle/s);
assert.match(adminPages, /Route Offers/);
assert.match(operatorDashboard, /Minimum journey revenue \(USD\)/);
assert.match(operatorDashboard, /complete two-leg journey/i);
```

Also assert the Site Admin route-offer creation path explicitly collects route-specific `min_seats`, `max_seats`, and `min_revenue_cents` rather than copying `vehicle.default_min_revenue_cents`.

- [ ] **Step 2: Write the failing database/allocation contract test**

Read the new migration path and assert it contains enforcement for:

```js
assert.match(sql, /vehicle.*route/i);
assert.match(sql, /max_seats/i);
assert.match(sql, /capacity|default_max_seats/i);
assert.match(sql, /unique|exclude|duplicate/i);
assert.match(sql, /min_revenue_cents/i);
assert.match(sql, /consideration|snapshot/i);
```

Add explicit assertions for protected admin/operator Route Offer RPC names used by `lib/data.ts`.

- [ ] **Step 3: Run the tests and verify RED**

Run:

```bash
node --test tests/route-offer-commercial-model.test.mjs tests/route-offer-allocation-contract.test.mjs
```

Expected: FAIL because Vehicle Admin still requests universal commercial values, Site Admin still calls the section `Route Assignments`, and the new migration does not yet exist.

- [ ] **Step 4: Commit the tests**

```bash
git add tests/route-offer-commercial-model.test.mjs tests/route-offer-allocation-contract.test.mjs
git commit -m "test: define route-specific vehicle commercial contract"
```

### Task 2: Make Route Offers authoritative and enforce commercial invariants in Supabase

**Files:**
- Create: `supabase/migrations/20260825_route_specific_vehicle_commercial_offers.sql`
- Test: `tests/route-offer-allocation-contract.test.mjs`

**Interfaces:**
- Consumes: existing `v2_vehicle_route_offers`, vehicles, routes, route-vehicle-type/operator-vehicle-type compatibility, allocation/consideration structures.
- Produces: revised `v2_admin_create_route_offer`, `v2_operator_update_route_offer`, activation functions, uniqueness/capacity validation, and preserved consideration snapshots.

- [ ] **Step 1: Inspect existing production definitions before writing replacement SQL**

From the database schema/migrations, capture the exact current definitions and signatures of:

```text
v2_admin_create_vehicle
v2_admin_create_route_offer
v2_admin_set_route_offer_active
v2_operator_update_route_offer
v2_operator_set_route_offer_active
v2_vehicle_route_offers
v2_operator_my_route_offers
vehicle consideration refresh/allocation RPCs
```

Do not guess table names or replace unrelated allocation logic.

- [ ] **Step 2: Add database validation for Route Offers**

Implement a shared protected validation path that rejects an offer when:

```text
min_seats < 1
max_seats < min_seats
max_seats > vehicle physical capacity
min_revenue_cents <= 0
vehicle/operator ownership is inconsistent
route does not permit the vehicle type
operator is not approved for the vehicle type where approval applies
another current active offer exists for the same vehicle + route
```

Use existing schema columns for physical capacity. Do not reinterpret a legacy commercial default as capacity unless the current schema genuinely uses that column as the physical capacity source.

- [ ] **Step 3: Preserve existing Route Offers and history**

The migration must not bulk-recalculate `min_revenue_cents`. Existing route-offer values remain unchanged. If current rows are effective-dated, close/create versions using the existing pattern; otherwise retain current IDs and ensure allocation/consideration rows snapshot commercial values before future edits.

- [ ] **Step 4: Update protected create/update/activation RPCs**

Ensure `v2_admin_create_route_offer` and `v2_operator_update_route_offer` call the same invariant validation. Activation must also reject a duplicate current active vehicle/route offer.

Keep the operator update interface logically equivalent to:

```text
p_offer_id
p_min_seats
p_max_seats
p_min_revenue_cents
p_preferred
p_threshold
p_discount_enabled
p_discount_bps
```

- [ ] **Step 5: Verify allocation reads Route Offer values**

Trace the current consideration refresh/allocation SQL. Ensure the applicable departure route joins the vehicle's current active Route Offer and snapshots at least:

```text
min_seats
max_seats
min_revenue_cents
min_value_threshold_ratio
post_min_discount_enabled
post_min_discount_bps
```

Remove any fallback that makes a vehicle commercially eligible solely from `default_min_revenue_cents`. A vehicle with no active Route Offer for the departure route is not an eligible commercial candidate.

- [ ] **Step 6: Run database contract tests**

```bash
node --test tests/route-offer-allocation-contract.test.mjs
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/20260825_route_specific_vehicle_commercial_offers.sql tests/route-offer-allocation-contract.test.mjs
git commit -m "feat: enforce route-specific vehicle commercial offers"
```

### Task 3: Remove route-independent commercial pricing from Site Admin Fleet

**Files:**
- Modify: `components/pages.tsx` in `OperatorDetail`
- Modify: `lib/data.ts` if the protected vehicle-create signature changes
- Test: `tests/route-offer-commercial-model.test.mjs`

**Interfaces:**
- Consumes: vehicle physical capacity fields and revised protected vehicle-create RPC.
- Produces: Site Admin vehicle creation that records vehicle facts only.

- [ ] **Step 1: Update the failing test to require physical vehicle fields only**

Assert that the `+ Add Vehicle` flow no longer prompts for `Minimum journey revenue (USD)` and does not pass `p_min_revenue_cents` as a commercial decision made during vehicle creation.

Require the Fleet display to use capacity wording, not a commercial min/max range.

- [ ] **Step 2: Revise Site Admin vehicle creation**

Change `OperatorDetail` so `+ Add Vehicle` collects the existing required physical/operational fields. At minimum it must collect/select:

```text
vehicle name
vehicle type
physical passenger capacity
```

If the existing database RPC still requires legacy default commercial parameters for compatibility, pass neutral compatibility values inside the data/RPC layer rather than presenting them as operator commercial settings. Document those parameters as deprecated in code and never use them as allocation authority.

- [ ] **Step 3: Revise Fleet display**

Replace output equivalent to:

```text
Boat A · 4–12 seats
```

with physical/operational information such as:

```text
Boat A · Speed Boat · capacity 12
```

Do not display minimum journey revenue in Fleet.

- [ ] **Step 4: Run regression test**

```bash
node --test tests/route-offer-commercial-model.test.mjs
```

Expected: Fleet-related assertions PASS; Route Offer assertions may remain RED until Task 4.

- [ ] **Step 5: Commit**

```bash
git add components/pages.tsx lib/data.ts tests/route-offer-commercial-model.test.mjs
git commit -m "refactor: keep vehicle admin operational only"
```

### Task 4: Replace Site Admin Route Assignments with explicit Route Offers

**Files:**
- Modify: `components/pages.tsx` in `OperatorDetail`
- Modify: `lib/data.ts`
- Test: `tests/route-offer-commercial-model.test.mjs`

**Interfaces:**
- Consumes: `adminCreateRouteOffer`, routes, vehicles, vehicle types and compatibility data.
- Produces: explicit Site Admin Route Offer creation and visibility.

- [ ] **Step 1: Rename the section and require explicit commercial entry**

Rename `Route Assignments` to `Route Offers`. The creation flow must explicitly select/collect:

```text
route
vehicle
minimum seats
maximum seats
minimum journey revenue USD
threshold override if required
post-minimum discount enabled
maximum discount percent
```

Do not use `vehicle.default_min_revenue_cents` or other legacy vehicle commercial defaults to populate the saved offer.

- [ ] **Step 2: Filter incompatible choices before submission**

Only offer vehicles whose type is permitted on the selected route and whose operator/type approval is valid using the existing route/operator vehicle-type datasets. Keep server-side validation from Task 2 authoritative even though the UI filters choices.

- [ ] **Step 3: Add commercial explanation**

Render the exact help text:

```text
Minimum revenue required for this vehicle to perform the complete two-leg journey on this route.
```

Also state that opposite-direction routes are configured independently.

- [ ] **Step 4: Display route-specific offer rows**

The table/list must show:

```text
Route | Vehicle | Min / max seats | Minimum journey revenue | Discount | Status
```

Use existing active/inactive controls and protected RPCs.

- [ ] **Step 5: Run model regression tests**

```bash
node --test tests/route-offer-commercial-model.test.mjs
```

Expected: PASS for Site Admin assertions.

- [ ] **Step 6: Commit**

```bash
git add components/pages.tsx lib/data.ts tests/route-offer-commercial-model.test.mjs
git commit -m "feat: manage route-specific offers in site admin"
```

### Task 5: Make Operator Route Offers explicit and safe

**Files:**
- Modify: `components/operator-dashboard.tsx`
- Modify: `lib/data.ts` only if needed for validation/error shape
- Test: `tests/route-offer-commercial-model.test.mjs`

**Interfaces:**
- Consumes: `v2_operator_my_route_offers`, `v2_operator_update_route_offer`, `v2_operator_set_route_offer_active`.
- Produces: operator self-service editing with whole-journey semantics and capacity-safe validation.

- [ ] **Step 1: Add approved help copy**

Immediately above/beside the commercial editor render:

```text
Minimum revenue required for this vehicle to perform the complete two-leg journey on this route.
```

Explain that operators choose the figure and that changing it changes future competitive allocation calculations.

- [ ] **Step 2: Validate numeric input before RPC call**

Client validation must reject:

```text
min seats < 1
max seats < min seats
max seats > displayed vehicle capacity when available
minimum journey revenue <= 0
threshold that is non-numeric when supplied
discount outside 0–100%
```

Server validation from Task 2 remains authoritative.

- [ ] **Step 3: Clarify route directionality**

Display route names as returned by the directional route model and add concise copy that the opposite direction is a separate Route Offer.

- [ ] **Step 4: Run model regression test**

```bash
node --test tests/route-offer-commercial-model.test.mjs
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add components/operator-dashboard.tsx lib/data.ts tests/route-offer-commercial-model.test.mjs
git commit -m "feat: clarify operator route offer economics"
```

### Task 6: Verify allocation snapshots and historical immutability

**Files:**
- Modify: `supabase/migrations/20260825_route_specific_vehicle_commercial_offers.sql` if verification exposes a missing snapshot rule
- Test: `tests/route-offer-allocation-contract.test.mjs`

**Interfaces:**
- Consumes: Route Offer values and existing consideration/confirmed allocation financial fields.
- Produces: proof that future offer edits do not rewrite historical decisions.

- [ ] **Step 1: Create two distinct offers for one vehicle in a controlled test dataset**

Example:

```text
Boat A + Antigua -> Barbuda: min seats 6, max 10, minimum revenue $900
Boat A + short Antigua route: min seats 3, max 10, minimum revenue $300
```

Verify both coexist because their `route_id` values differ.

- [ ] **Step 2: Verify duplicate active offer rejection**

Attempt a second current active `Boat A + Antigua -> Barbuda` offer. Expected: protected function rejects it with a clear duplicate/current-offer error.

- [ ] **Step 3: Verify capacity enforcement**

For a capacity-10 vehicle, attempt `max_seats=11`. Expected: rejected.

- [ ] **Step 4: Verify route-specific consideration snapshots**

Refresh considerations for departures on both routes. Confirm the Antigua -> Barbuda consideration snapshots `$900` and its seat thresholds while the short route snapshots `$300` and its own thresholds.

- [ ] **Step 5: Verify historical immutability**

After a consideration/confirmed allocation has snapshotted the $900 offer, edit the future Route Offer to $850. Confirm the historical consideration/allocation/settlement inputs remain at their original snapshot values and only subsequent evaluations use $850.

- [ ] **Step 6: Run contract tests and build**

```bash
node --test tests/route-offer-allocation-contract.test.mjs tests/route-offer-commercial-model.test.mjs
npm run build
```

Expected: all tests PASS and Next.js production build succeeds.

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/20260825_route_specific_vehicle_commercial_offers.sql tests/route-offer-allocation-contract.test.mjs
git commit -m "test: verify route offer allocation snapshots"
```

### Task 7: Production-readiness verification

**Files:**
- No new production files expected; fix only defects revealed by verification.

**Interfaces:**
- Consumes: completed implementation.
- Produces: evidence for merge/deploy decision.

- [ ] **Step 1: Run the full repository test set**

```bash
node --test tests/*.test.mjs
```

Expected: PASS.

- [ ] **Step 2: Run production build**

```bash
npm run build
```

Expected: PASS with no TypeScript/build errors.

- [ ] **Step 3: Review diff specifically for forbidden regressions**

Confirm:

```text
Vehicle creation no longer asks for universal minimum journey revenue.
No allocation path uses vehicle.default_min_revenue_cents as route-independent authority.
Existing Route Offer min_revenue_cents values are not bulk rewritten.
Operator and Site Admin both describe whole two-leg journey economics.
Opposite-direction routes remain independent.
```

- [ ] **Step 4: Deploy preview and perform role checks**

As Site Admin: create/view a vehicle and two Route Offers.

As Operator: edit one Route Offer and verify the other route is unchanged.

As Site Admin Journey Detail: refresh a future departure's considerations and verify the route-specific minimum revenue/base seat price displayed by the allocation engine.

- [ ] **Step 5: Only after green verification, request merge/deploy approval**

Do not merge merely because code compiles. Report the test/build/preview evidence and any database migration requirement before production deployment.
