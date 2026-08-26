# Operator Vehicle Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one operator-scoped vehicle editor that creates and edits vehicle facts, preferred captain and geographically eligible Route Offers with explicit discount and below-minimum operating rules.

**Architecture:** Add an atomic Supabase aggregate RPC and operator-scoped read views, with every ownership/compatibility/geography rule revalidated in Postgres. Build focused React form components around a typed draft model; the existing operator dashboard owns loading and save orchestration while child components own vehicle and Route Offer presentation.

**Tech Stack:** PostgreSQL/Supabase, Next.js 15, React 19, TypeScript, CSS, SQL contract/behaviour tests.

**Spec:** `docs/superpowers/specs/2026-08-26-operator-vehicle-editor-design.md`

## Global Constraints

- The business name is always “Pace Shuttles”.
- Route Offer minimum revenue is USD for the complete two-leg journey.
- Route eligibility is derived from authenticated operator geography; the form never asks for country or city.
- Normal countries filter by `operator.country_id`; countries with `countries.is_large = true` additionally filter by `operator.locality_id`.
- Every Route Offer must match the vehicle Transport Type through an active `route_vehicle_types` row.
- Below-minimum mode is exactly `never`, `route_default` or `custom_threshold`; null threshold means `route_default` only.
- Existing offers with non-null thresholds migrate to `custom_threshold`; null thresholds migrate to `route_default`.
- Existing Route Offers are ended/deactivated, never hard-deleted, and confirmed commercial snapshots are immutable.
- Security-definer RPCs derive operator access from `auth.uid()` and explicitly revoke execution from `PUBLIC` and `anon` before granting `authenticated`.

---

## File structure

- `supabase/migrations/20260826190000_operator_vehicle_editor.sql` — below-minimum model, read views, eligibility function, atomic save RPC and allocation snapshot propagation.
- `supabase/tests/operator_vehicle_editor_contract.sql` — schema, view, privilege and function-contract assertions.
- `supabase/tests/operator_vehicle_editor_behavior.sql` — transactional authorization, route geography, captain, capacity, discount and atomicity tests.
- `lib/operator-vehicle-editor.ts` — editor types, draft conversion and deterministic client validation.
- `lib/data.ts` — typed read/RPC wrappers.
- `components/operator-vehicle-editor.tsx` — vehicle list, vehicle form, route selector and Route Offer cards.
- `components/operator-dashboard.tsx` — load editor reference data and replace prompt-driven fleet/offer administration.
- `app/globals.css` — responsive editor styling.

---

### Task 1: Persist unambiguous below-minimum terms through allocation

**Files:**
- Create: `supabase/migrations/20260826190000_operator_vehicle_editor.sql`
- Create: `supabase/tests/operator_vehicle_editor_contract.sql`
- Create: `supabase/tests/operator_vehicle_editor_behavior.sql`
- Modify: `supabase/migrations/20260826033000_complete_consideration_commercial_snapshot.sql` only if the repository's historical snapshot definition must document the new field; do not rewrite an already-applied migration.

**Interfaces:**
- Produces: `vehicle_route_offers.below_minimum_operation_mode text NOT NULL`
- Produces: `vehicle_considerations.below_minimum_operation_mode text NOT NULL`
- Preserves: `min_value_threshold_ratio numeric`, with null valid only for `route_default` and `never`.

- [ ] **Step 1: Create the migration shell using the installed CLI**

Run `supabase --version`, `supabase migration --help`, then `supabase migration new operator_vehicle_editor`. Rename only if necessary so the resulting tracked path is `supabase/migrations/20260826190000_operator_vehicle_editor.sql`.

- [ ] **Step 2: Write failing contract assertions**

In `operator_vehicle_editor_contract.sql`, wrap assertions in `begin; ... rollback;` and require both tables to expose a non-null mode column with a check constraint allowing only:

```sql
('never', 'route_default', 'custom_threshold')
```

Also require `pace_v2.protect_allocated_consideration_snapshot()` to reference `below_minimum_operation_mode`.

- [ ] **Step 3: Run the contract test and verify failure**

Run the SQL against a development database using the supported Supabase CLI command discovered in Step 1, or MCP `execute_sql` when no local database is linked. Expect failure that `below_minimum_operation_mode` is missing.

- [ ] **Step 4: Implement columns, migration and consistency checks**

Add both columns, backfill offers with:

```sql
case when min_value_threshold_ratio is null
  then 'route_default'
  else 'custom_threshold'
end
```

Backfill considerations from their source offer where available, otherwise apply the same threshold rule. Add checks enforcing:

```sql
below_minimum_operation_mode <> 'custom_threshold'
or min_value_threshold_ratio is not null
```

and requiring a custom ratio to be `> 0 and <= 1`. Replace `get_eligible_vehicle_offers`, `refresh_vehicle_considerations`, `evaluate_t72_booked_parties`, `protect_allocated_consideration_snapshot` and `v2_admin_open_revenue_rescue` so mode travels with the commercial snapshot and `never` cannot confirm/rescue below minimum.

- [ ] **Step 5: Write and run behaviour assertions**

Verify: existing null/non-null values map correctly; invalid modes fail; custom-with-null fails; allocated consideration mode cannot change; `never` remains ineligible below minimum while `custom_threshold` becomes eligible at its configured ratio.

- [ ] **Step 6: Run all existing SQL capacity/snapshot tests**

Run `route_offer_capacity_contract.sql`, `route_offer_capacity_behavior.sql`, and both new SQL tests. Expect every transaction to complete and roll back without an exception.

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/20260826190000_operator_vehicle_editor.sql supabase/tests/operator_vehicle_editor_contract.sql supabase/tests/operator_vehicle_editor_behavior.sql
git commit -m "feat: model below-minimum route operation"
```

---

### Task 2: Add operator-scoped editor reads and atomic save RPC

**Files:**
- Modify: `supabase/migrations/20260826190000_operator_vehicle_editor.sql`
- Modify: `supabase/tests/operator_vehicle_editor_contract.sql`
- Modify: `supabase/tests/operator_vehicle_editor_behavior.sql`

**Interfaces:**
- Produces: `public.v2_operator_vehicle_editor`
- Produces: `public.v2_operator_vehicle_editor_captains`
- Produces: `public.v2_operator_vehicle_editor_routes`
- Produces: `public.v2_operator_save_vehicle(p_vehicle jsonb) returns uuid`

- [ ] **Step 1: Add failing read-contract tests**

Require all three views to use `security_invoker = true`, be granted only to `authenticated`, and expose stable UUIDs plus labels. Require the route view to include `route_id`, `route_name`, `vehicle_type_id`, `country_id`, `locality_id`; captain view to include `captain_id`, `captain_name`, `vehicle_type_id`; editor view to expose vehicle facts, `preferred_captain_id` and Route Offer commercial fields.

- [ ] **Step 2: Add failing authorization and eligibility tests**

Using transaction-local JWT claims/fixtures, assert an operator sees only its own vehicles/captains. Assert an Antigua operator sees active Antigua routes only. For a fixture country with `is_large=true`, assert only routes whose `locality_id` equals the operator's `locality_id` appear. Assert routes of another Transport Type and already-attached routes are excluded for the selected vehicle.

- [ ] **Step 3: Implement security-invoker read views**

Join through active `operator_memberships` using `auth.uid()`. Derive normal-country eligibility with `r.country_id = o.country_id`; for large countries additionally require `r.locality_id = o.locality_id`. Join `route_vehicle_types` by requested/vehicle Transport Type, active/effective dates, and `operator_vehicle_types.status = 'approved'`.

- [ ] **Step 4: Add failing aggregate-save tests**

Test one JSON payload shaped as:

```json
{
  "vehicle_id": null,
  "vehicle_type_id": "00000000-0000-0000-0000-000000000000",
  "name": "Sea Sea Rider",
  "description": "Premium speed boat",
  "picture_url": null,
  "capacity_seats": 10,
  "active": true,
  "preferred_captain_id": null,
  "route_offers": [{
    "offer_id": null,
    "route_id": "00000000-0000-0000-0000-000000000000",
    "min_seats": 4,
    "max_seats": 10,
    "min_revenue_cents": 140000,
    "post_min_discount_enabled": true,
    "post_min_discount_bps": 1500,
    "below_minimum_operation_mode": "custom_threshold",
    "min_value_threshold_ratio": 0.8,
    "active": true,
    "remove": false
  }]
}
```

Assert rejection for cross-operator vehicle/captain/offer IDs, wrong type, wrong country/city, duplicate routes, maximum seats over capacity, enabled discount without valid basis points, custom mode without ratio, and `never` with a non-null ratio. Deliberately make the final offer invalid and assert the earlier vehicle/captain changes roll back.

- [ ] **Step 5: Implement `v2_operator_save_vehicle`**

Validate `auth.uid()` has exactly one relevant active operator membership for the target existing vehicle, or derive the operator from membership for a create. Validate every scalar before mutation. Insert/update the vehicle, deactivate old priority-1 captain preferences and upsert the chosen eligible captain preference, then upsert submitted offers. For `remove=true`, set `active=false`, `effective_to=now()`; never delete. Reject persisted offers omitted accidentally unless the client explicitly sends `remove=true`.

- [ ] **Step 6: Lock down privileges**

Apply:

```sql
revoke all on function public.v2_operator_save_vehicle(jsonb) from public, anon;
grant execute on function public.v2_operator_save_vehicle(jsonb) to authenticated;
```

Apply explicit view grants and keep base `pace_v2` tables unavailable to the browser beyond existing protected access.

- [ ] **Step 7: Run all SQL tests and advisors**

Run all four SQL test files. Run Supabase security and performance advisors; resolve any new finding caused by these objects before continuing.

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/20260826190000_operator_vehicle_editor.sql supabase/tests/operator_vehicle_editor_contract.sql supabase/tests/operator_vehicle_editor_behavior.sql
git commit -m "feat: add operator vehicle editor database contract"
```

---

### Task 3: Add typed client draft and validation

**Files:**
- Create: `lib/operator-vehicle-editor.ts`
- Create: `lib/operator-vehicle-editor.test.ts`
- Modify: `package.json`
- Modify: `package-lock.json`
- Modify: `lib/data.ts`

**Interfaces:**
- Produces: `VehicleEditorDraft`, `RouteOfferDraft`, `EditorReferenceData`
- Produces: `vehicleToDraft(vehicle, offers): VehicleEditorDraft`
- Produces: `blankVehicleDraft(): VehicleEditorDraft`
- Produces: `validateVehicleDraft(draft): Record<string,string>`
- Produces: `toVehicleSavePayload(draft): Record<string,unknown>`
- Produces: `loadOperatorVehicleEditor*()` and `operatorSaveVehicle(payload)` wrappers.

- [ ] **Step 1: Add Vitest as a pinned dev dependency and test script**

Run `npm install --save-dev --save-exact vitest@latest`, retain the exact resolved version in both package files, and add `"test": "vitest run"`.

- [ ] **Step 2: Write failing pure-function tests**

Cover blank creation, cents/basis-point/ratio conversion, capacity errors, duplicate routes, discount-disabled forcing zero, the three below-minimum modes, and preservation of explicit `remove` markers for persisted offers.

- [ ] **Step 3: Run tests and verify failure**

Run `npm test -- lib/operator-vehicle-editor.test.ts`. Expect failure because the module/functions do not exist.

- [ ] **Step 4: Implement the typed draft module**

Keep all currency text in dollars in the form and convert once to integer cents in `toVehicleSavePayload`. Keep discount text as percent and convert once to basis points. Convert custom threshold percent to ratio; submit null for `never` and `route_default`.

- [ ] **Step 5: Add data wrappers**

Add view loaders for editor vehicles, captains and routes. Add:

```ts
export const operatorSaveVehicle = (payload: Record<string,unknown>) =>
  rpc('v2_operator_save_vehicle', {p_vehicle: payload});
```

Remove no existing wrapper until the new UI is verified.

- [ ] **Step 6: Run unit tests and TypeScript build**

Run `npm test -- lib/operator-vehicle-editor.test.ts` and `npm run build`. Expect both to pass.

- [ ] **Step 7: Commit**

```bash
git add package.json package-lock.json lib/operator-vehicle-editor.ts lib/operator-vehicle-editor.test.ts lib/data.ts
git commit -m "feat: add vehicle editor draft model"
```

---

### Task 4: Build the responsive operator vehicle editor

**Files:**
- Create: `components/operator-vehicle-editor.tsx`
- Create: `components/operator-vehicle-editor.test.tsx`
- Modify: `components/operator-dashboard.tsx`
- Modify: `app/globals.css`

**Interfaces:**
- Consumes: all Task 3 types/helpers and data wrappers.
- Produces: `OperatorVehicleEditor` component accepting loaded vehicles, offers, captains, eligible routes, busy state and async save callback.

- [ ] **Step 1: Add React Testing Library dependencies and failing component tests**

Install pinned `@testing-library/react`, `@testing-library/user-event` and `jsdom`. Test: selecting a vehicle populates fields; Add Vehicle is blank; captain options follow Transport Type; Add Route excludes wrong type/geography/already attached; discount and custom-threshold fields enable conditionally; removing a persisted offer marks it; validation prevents save; successful save submits one aggregate payload.

- [ ] **Step 2: Run the component test and verify failure**

Run `npm test -- components/operator-vehicle-editor.test.tsx`. Expect failure because the component does not exist.

- [ ] **Step 3: Implement vehicle list and details form**

Use controlled inputs with visible labels. Provide Add Vehicle, save, cancel and deactivate controls. Do not use `window.prompt`. Preserve the current date-blocking action alongside the editor.

- [ ] **Step 4: Implement Route Offer cards and route selector**

Filter the already server-scoped route list again by selected Transport Type and unattached route IDs. Render minimum/maximum seats, minimum revenue, discount toggle/percentage, below-minimum select and conditional threshold percentage. Add `Save and add another route` behaviour without saving the vehicle prematurely.

- [ ] **Step 5: Integrate into the dashboard**

Replace the separate prompt-driven `Fleet` and `Offers` editing surfaces with the editor under `Fleet & availability`. Keep a read-only Route Offers tab only if it adds genuine overview value; otherwise remove the duplicate tab. Refresh all editor datasets after save.

- [ ] **Step 6: Add responsive CSS matching the approved mockup**

Desktop uses a fixed-width fleet rail and flexible editor. Under 900px, stack the fleet selector above the form. Route Offer fields collapse from a multi-column grid to one column under 700px. Ensure no horizontal page scrolling at 375px.

- [ ] **Step 7: Run unit, component and production builds**

Run `npm test` and `npm run build`. Expect all tests and Next.js compilation to pass.

- [ ] **Step 8: Commit**

```bash
git add components/operator-vehicle-editor.tsx components/operator-vehicle-editor.test.tsx components/operator-dashboard.tsx app/globals.css package.json package-lock.json
git commit -m "feat: build operator vehicle editor"
```

---

### Task 5: Apply safely and verify the complete operator flow

**Files:**
- Modify only if verification exposes a defect in files created/changed above.

**Interfaces:**
- Consumes: migration, SQL tests, client tests and completed editor.
- Produces: verified production-ready branch and deployment evidence.

- [ ] **Step 1: Rebase/fetch against current main in an isolated worktree**

Use the required git-worktree skill before implementation if this plan is executed outside the current isolated branch. Preserve unrelated user changes.

- [ ] **Step 2: Apply and verify the migration in a safe Supabase environment**

Prefer an existing development branch. If none exists, do not create a paid Supabase branch without the required cost confirmation. Run SQL tests and query the three views as an operator identity.

- [ ] **Step 3: Run Supabase advisors**

Run security and performance advisors and fix any new issue attributable to this migration. Record unrelated pre-existing findings separately.

- [ ] **Step 4: Verify in the browser**

As the E2E operator, verify: existing vehicle edit; blank vehicle creation; preferred captain; Antigua Speed Boat route filtering; add/edit/remove offer; discount toggle; all three below-minimum modes; cancel discards; save refreshes; mobile 375px layout. Confirm no console or network errors.

- [ ] **Step 5: Verify authorization negatively**

Attempt the aggregate RPC with another operator's vehicle, captain, offer and an out-of-geography route. Expect each request to fail and confirm no partial database mutation occurred.

- [ ] **Step 6: Run the full local verification set**

Run `npm test`, `npm run build`, all SQL tests and `git diff --check`. Review `git status --short` so generated `.next` and `node_modules` remain untracked/uncommitted.

- [ ] **Step 7: Commit any verification correction separately**

Review `git diff --name-only`, stage each corrected editor file by its explicit path, inspect `git diff --cached`, then run `git commit -m "fix: complete vehicle editor verification"`. If verification required no correction, create no empty commit.
