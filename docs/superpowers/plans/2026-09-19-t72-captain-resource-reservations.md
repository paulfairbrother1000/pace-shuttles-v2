# T-72 Captain Resource Reservations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Guarantee that every paid vehicle demand has a distinct eligible captain, reserve that captain through T-72 and T-24, and remove unstaffable vehicles without allowing the lifecycle or communications to fail silently.

**Architecture:** Add a private staged captain-reservation ledger protected by a PostgreSQL exclusion constraint. Paid allocation creates provisional claims, T-72 rebalances and promotes the winning claims, and T-24 consumes those claims to create the existing confirmed captain assignments. All paths use one complete-duty window including paired returns and a 30-minute turnaround.

**Tech Stack:** PostgreSQL 15 / Supabase migrations and RLS, PL/pgSQL allocation functions, Node `node:test` contract tests, executable transactional SQL fixtures, Next.js/React Site Admin presentation.

**Spec:** `docs/superpowers/specs/2026-09-19-t72-captain-resource-reservations-design.md`

## Global Constraints

- One captain may have only one active reservation during overlapping half-open duty ranges.
- The resource range runs from outbound departure through return arrival, plus exactly 30 minutes; missing arrival retains the existing eight-hour fallback before the allowance.
- Return journeys are paired only through explicit `journey_pairs`; never infer a return from route names, dates or times.
- Provisional reservations begin only when paid demand activates a vehicle consideration, not for catalogue listings or abandoned quotes.
- `discarded_t72` with reason code `captain_conflict` is a Pace Shuttles resource decision and must never create operator-withdrawal liability.
- `captain_assignments` remains the confirmed customer/captain interface identity; reservations are private planning and audit data.
- Reservation mutations remain inaccessible to `PUBLIC`, `anon` and general `authenticated` callers.
- Existing pay-then-allocate failure handling remains authoritative: a paid booking that cannot obtain a conflict-free claim returns a non-allocated result so the existing automatic refund path runs.
- Existing one-way journeys remain compatible.
- No live migration, production deployment or data backfill occurs without explicit approval after preview evidence.

## Review Focus

- Two payments on different departures race for the same captain: at most one allocation may commit, and the other must enter the existing refund-required path rather than becoming an unstaffed paid booking. Covered in Task 2.
- A paired return finishes near local midnight or during an offset change: the reservation must use stored UTC timestamps and remain active through return arrival plus 30 minutes. Covered in Task 1.
- A captain becomes inactive or loses vehicle-type eligibility after T-72: T-24 must atomically rematch or stop for manual review without partial confirmations. Covered in Task 4.
- A replacement cannot reserve its new captain: the old reservation and allocation must remain intact. Covered in Task 4.
- Backfill encounters existing conflicting confirmed assignments: it must preserve confirmed truth, record an alert and avoid inventing or overwriting a reservation. Covered in Task 6.

---

### Task 1: Private Reservation Ledger and Canonical Duty Window

**Files:**
- Create with `npx supabase migration new captain_duty_reservations`: capture the CLI-reported path in the shell variable `migration_path`, verify it exists, and record `Migration: $migration_path` in the execution ledger. Every later reference to `$migration_path` consumes that exact recorded file.
- Create: `tests/captain-resource-reservations.test.mjs`
- Create: `supabase/tests/captain_resource_reservations_behavior.sql`

**Interfaces:**
- Consumes: `pace_v2.captain_duty_resource_window(uuid)` and the existing `journey_pairs` model.
- Produces: `pace_v2.captain_duty_reservations`, active states `provisional|held_t72|confirmed_t24`, `pace_v2.captain_reservation_window(uuid) returns tstzrange`, and the updated `captain_duty_resource_window(uuid)` whose `scheduled_end_ts` includes the 30-minute allowance.

- [ ] **Step 1: Write the failing Node contract test**

Add tests that locate the CLI-generated migration by its `_captain_duty_reservations.sql` suffix and require these contracts:

```js
test('captain reservations are private and exclude overlapping active ranges',()=>{
  assert.match(sql,/create table pace_v2\.captain_duty_reservations/i);
  assert.match(sql,/state text not null check\s*\(state in\s*\('provisional','held_t72','confirmed_t24','released'\)\)/i);
  assert.match(sql,/exclude using gist\s*\(captain_id with =,\s*duty_window with &&\)/i);
  assert.match(sql,/where \(state in \('provisional','held_t72','confirmed_t24'\)\)/i);
  assert.match(sql,/alter table pace_v2\.captain_duty_reservations enable row level security/i);
  assert.match(sql,/revoke all on pace_v2\.captain_duty_reservations from public,anon,authenticated/i);
});

test('every captain conflict uses the full duty plus thirty minutes',()=>{
  assert.match(sql,/coalesce\(return_leg\.scheduled_arrival_ts,outbound\.scheduled_arrival_ts,[\s\S]*interval '8 hours'[\s\S]*\)\s*\+\s*interval '30 minutes'/i);
});
```

- [ ] **Step 2: Run the test and verify RED**

Run: `node --test tests/captain-resource-reservations.test.mjs`

Expected: FAIL because no `_captain_duty_reservations.sql` migration exists.

- [ ] **Step 3: Create the migration through the Supabase CLI**

Run: `npx supabase migration new captain_duty_reservations`

Expected: one new empty migration path ending `_captain_duty_reservations.sql`. Record that exact path in the plan ledger before editing it.

- [ ] **Step 4: Implement the private schema and window**

Add `btree_gist` only if absent, then create the table and constraints with this public contract:

```sql
create extension if not exists btree_gist with schema extensions;

create table pace_v2.captain_duty_reservations(
  id uuid primary key default gen_random_uuid(),
  departure_id uuid not null references pace_v2.departures(id),
  vehicle_consideration_id uuid not null references pace_v2.vehicle_considerations(id),
  operator_id uuid not null references pace_v2.operators(id),
  vehicle_id uuid not null references pace_v2.vehicles(id),
  captain_id uuid not null references pace_v2.captains(id),
  duty_start_ts timestamptz not null,
  duty_end_ts timestamptz not null,
  duty_window tstzrange generated always as
    (tstzrange(duty_start_ts,duty_end_ts,'[)')) stored,
  state text not null check(state in('provisional','held_t72','confirmed_t24','released')),
  confirmed_allocation_id uuid references pace_v2.confirmed_allocations(id),
  captain_assignment_id uuid references pace_v2.captain_assignments(id),
  source text not null,
  engine_version text not null,
  created_at timestamptz not null default now(),
  promoted_at timestamptz,
  released_at timestamptz,
  release_reason text,
  check(duty_end_ts>duty_start_ts),
  check((state='released')=(released_at is not null))
);

alter table pace_v2.captain_duty_reservations
  add constraint captain_duty_reservations_no_overlap
  exclude using gist(captain_id with =,duty_window with &&)
  where(state in('provisional','held_t72','confirmed_t24'))
  deferrable initially immediate;

create unique index captain_duty_reservations_one_active_consideration
  on pace_v2.captain_duty_reservations(vehicle_consideration_id)
  where state in('provisional','held_t72','confirmed_t24');
```

Replace `captain_duty_resource_window(uuid)` so `scheduled_end_ts` is the final configured arrival/fallback plus `interval '30 minutes'`. Add `captain_reservation_window(uuid)` as a stable private SQL wrapper returning `tstzrange(scheduled_start_ts,scheduled_end_ts,'[)')`. Enable RLS, revoke table privileges from public client roles, and revoke both helper functions from all client roles.

- [ ] **Step 5: Add executable transactional behavior tests**

In `supabase/tests/captain_resource_reservations_behavior.sql`, use existing fixture patterns to assert:

```sql
-- The fixture setup creates these deterministic FK identities and an existing
-- 14:00-16:00 active claim for captain
-- 00000000-0000-0000-0000-000000004001 on consideration
-- 00000000-0000-0000-0000-000000001001.
select throws_ok(
  $$insert into pace_v2.captain_duty_reservations(
      departure_id,vehicle_consideration_id,operator_id,vehicle_id,captain_id,
      duty_start_ts,duty_end_ts,state,source,engine_version
    ) values (
      '00000000-0000-0000-0000-000000000002',
      '00000000-0000-0000-0000-000000001002',
      '00000000-0000-0000-0000-000000002001',
      '00000000-0000-0000-0000-000000003002',
      '00000000-0000-0000-0000-000000004001',
      '2026-10-01 15:30:00+00','2026-10-01 17:00:00+00',
      'provisional','fixture','fixture-v1'
    )$$,
  '23P01',null,
  'one captain cannot hold overlapping active duty ranges'
);

select lives_ok(
  $$insert into pace_v2.captain_duty_reservations(
      departure_id,vehicle_consideration_id,operator_id,vehicle_id,captain_id,
      duty_start_ts,duty_end_ts,state,source,engine_version
    ) values (
      '00000000-0000-0000-0000-000000000003',
      '00000000-0000-0000-0000-000000001003',
      '00000000-0000-0000-0000-000000002001',
      '00000000-0000-0000-0000-000000003003',
      '00000000-0000-0000-0000-000000004001',
      '2026-10-01 16:00:00+00','2026-10-01 17:30:00+00',
      'provisional','fixture','fixture-v1'
    )$$,
  'a captain can serve the next non-overlapping duty'
);
```

Also assert a paired fixture ends at return arrival plus 30 minutes and that `anon` and `authenticated` lack table privileges.

- [ ] **Step 6: Run GREEN verification**

Run: `node --test tests/captain-resource-reservations.test.mjs`

Expected: PASS.

Run when a test database is configured: `psql "$SUPABASE_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/captain_resource_reservations_behavior.sql`

Expected: transaction rolls back after every pgTAP assertion passes.

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/*_captain_duty_reservations.sql tests/captain-resource-reservations.test.mjs supabase/tests/captain_resource_reservations_behavior.sql
git commit -m "feat: add private captain duty reservations"
```

### Task 2: Provisional Claims During Paid Allocation

**Files:**
- Modify: `$migration_path` recorded in Task 1
- Modify: `tests/captain-resource-reservations.test.mjs`
- Modify: `supabase/tests/captain_resource_reservations_behavior.sql`

**Interfaces:**
- Consumes: Task 1 reservation table and duty-window helper; `pace_v2.get_live_party_offer_candidates(uuid,integer)`; `pace_v2.allocate_paid_booking(uuid)`; `pace_v2.cancel_booking_and_request_refund(uuid,integer,text,text)`.
- Produces: `pace_v2.captain_candidates_for_consideration(uuid) returns table(captain_id uuid,priority integer)`, `pace_v2.reconcile_departure_captain_reservations(uuid,text,text) returns table(outcome text,reserved_count integer,unreserved_consideration_ids uuid[])`, and paid allocation/cancellation integration.

- [ ] **Step 1: Extend failing tests for the public behavior**

Add contract assertions for the exact signatures and an executable fixture with two simultaneous departures, one operator, two vehicles and one captain. The fixture calls the real allocation path for both paid bookings and asserts:

```sql
select results_eq(
  $$select count(*) from pace_v2.captain_duty_reservations
    where state='provisional'$$,
  array[1::bigint],
  'only one overlapping paid vehicle demand can reserve the captain'
);

select results_eq(
  $$select count(*) from pace_v2.bookings
    where id=second_booking and status='booked'$$,
  array[0::bigint],
  'the losing payment cannot become an unstaffed booking'
);
```

Add a cancellation assertion proving the final qualifying allocation releases the claim, while cancelling one of several bookings on the same vehicle does not.

- [ ] **Step 2: Run RED verification**

Run: `node --test tests/captain-resource-reservations.test.mjs`

Expected: FAIL because the candidate and reconciliation functions are absent.

- [ ] **Step 3: Implement deterministic candidate selection**

`captain_candidates_for_consideration` must return only active captains owned by the consideration's operator, eligible for the vehicle type, permitted by the route-preferred/default-vehicle rules, and free of overlapping active reservations or confirmed assignments. Order by route preference first, then vehicle preference priority, then captain UUID for stable ties.

The function signature is:

```sql
create or replace function pace_v2.captain_candidates_for_consideration(
  p_consideration_id uuid
) returns table(captain_id uuid,priority integer)
language sql stable security definer set search_path='';
```

Revoke it from all API roles because it exposes internal staffing identities.

- [ ] **Step 4: Implement atomic reconciliation**

`reconcile_departure_captain_reservations` must:

- accept only `provisional` or `held_t72` target states;
- advisory-lock the departure and every candidate captain in sorted UUID order;
- collect demanded considerations (`assigned_seats>0` and live statuses);
- use a recursive injective match so each demanded vehicle receives one distinct candidate;
- preserve valid confirmed/T-72 claims ahead of provisional claims;
- upsert exact reservations with the canonical resource window;
- release no-longer-demanded provisional/held claims with a supplied lifecycle reason;
- catch exclusion violation `23P01`, recompute once under locks, and return `unavailable` rather than leaking a partial claim;
- return `reserved` only when every demanded consideration has an active reservation.

Use this exact return contract:

```sql
returns table(
  outcome text,
  reserved_count integer,
  unreserved_consideration_ids uuid[]
)
```

- [ ] **Step 5: Integrate live offers and payment allocation**

Replace the captain feasibility checks in `get_live_party_offer_candidates` so an offered consideration must have at least one candidate under the canonical window and cannot conflict with active claims.

Replace `allocate_paid_booking` preserving its existing return columns. After inserting the booking allocation and refreshing totals, call:

```sql
select * into reservation_result
from pace_v2.reconcile_departure_captain_reservations(
  b.departure_id,'provisional','paid-allocation-v1'
);
```

If the result is not `reserved`, cancel the just-created booking allocation, refresh totals/states, and return `unavailable`. Do not throw: `v2_system_mark_stripe_paid` must continue into its existing refund-required branch.

After booking cancellation changes allocation status, call reconciliation. It releases only claims whose consideration no longer carries a qualifying paid party.

- [ ] **Step 6: Verify RED→GREEN and concurrency behavior**

Run: `node --test tests/captain-resource-reservations.test.mjs`

Expected: PASS.

Run the executable fixture twice concurrently against the preview database using two `psql` sessions. Expected: exactly one overlapping claim and no deadlock; the loser returns `unavailable` and the established order fulfillment becomes `refund_required`.

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/*_captain_duty_reservations.sql tests/captain-resource-reservations.test.mjs supabase/tests/captain_resource_reservations_behavior.sql
git commit -m "feat: reserve captains for paid vehicle demand"
```

### Task 3: T-72 Holds, Vehicle Removal and Communications Gate

**Files:**
- Modify: `$migration_path` recorded in Task 1
- Modify: `tests/captain-resource-reservations.test.mjs`
- Modify: `supabase/tests/captain_resource_reservations_behavior.sql`
- Modify: `tests/t72-operator-email-content.test.mjs`

**Interfaces:**
- Consumes: Task 2 reconciliation result; `pace_v2.plan_t72_whole_party_allocations(uuid)`; `pace_v2.evaluate_t72_booked_parties(uuid,text)`; `pace_v2.process_departure_t72(uuid,text,boolean)`.
- Produces: held T-72 reservations, `vehicle_considerations.captain_resource_reason`, `T72_CAPTAIN_CONFLICT` allocation evidence and operational alerts, and an operator-email gate requiring `held_t72`.

- [ ] **Step 1: Write failing T-72 behavior tests**

Add a fixture with three same-operator vehicles, enough paid seats to use all three, and only two eligible captains. Assert that T-72:

```sql
select results_eq(
  $$select count(*) from pace_v2.captain_duty_reservations
    where departure_id=test_departure and state='held_t72'$$,
  array[2::bigint],
  'T-72 holds one distinct captain per staffable vehicle'
);

select results_eq(
  $$select count(*) from pace_v2.vehicle_considerations
    where departure_id=test_departure
      and status='discarded_t72'
      and captain_resource_reason='captain_conflict'$$,
  array[1::bigint],
  'the unstaffable vehicle is removed as a resource decision'
);
```

Assert the journey becomes `at_risk` with a high-priority `captain_resource_shortage` alert when the two held vehicles cannot cover all paid parties. Assert no T-72 operator email is queued for the discarded vehicle.

- [ ] **Step 2: Run RED verification**

Run: `node --test tests/captain-resource-reservations.test.mjs tests/t72-operator-email-content.test.mjs`

Expected: FAIL because T-72 does not promote reservations or store the conflict reason.

- [ ] **Step 3: Add structured resource reason**

Add:

```sql
alter table pace_v2.vehicle_considerations
  add column if not exists captain_resource_reason text
  check(captain_resource_reason is null or captain_resource_reason in(
    'captain_conflict','no_eligible_captain','captain_inactive','captain_ineligible'
  ));
```

Clear the reason only when the consideration becomes staffable again. Never populate `withdrawn_at`, `withdrawal_reason` or operator liability evidence for this resource decision.

- [ ] **Step 4: Integrate T-72 planning and holding**

After whole-party rebalancing and refreshed totals, `evaluate_t72_booked_parties` calls reconciliation with `held_t72`. For every unreserved demanded consideration:

- set status `discarded_t72`, `t72_discarded_at=now()` and `captain_resource_reason='captain_conflict'`;
- release any stale provisional claim;
- refresh totals and recompute uncovered bookings;
- record allocation decision reason `T72_CAPTAIN_CONFLICT` and a high-priority `captain_resource_shortage:<departure_id>` alert containing only consideration, vehicle, operator and conflicting-departure identifiers;
- set departure/bookings `at_risk` when any qualifying paid booking is uncovered.

Update `process_departure_t72` so its operator notification query joins an active `held_t72` reservation for each under-consideration vehicle. The informative email metadata uses the reserved captain, not a merely preferred captain.

- [ ] **Step 5: Verify T-72 behavior and regressions**

Run: `node --test tests/captain-resource-reservations.test.mjs tests/t72-t24-allocation.test.mjs tests/t72-operator-email-content.test.mjs tests/distinct-captain-capacity.test.mjs`

Expected: PASS.

Run the SQL fixture against preview. Expected: every assertion passes and transaction rolls back.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/*_captain_duty_reservations.sql tests/captain-resource-reservations.test.mjs tests/t72-operator-email-content.test.mjs supabase/tests/captain_resource_reservations_behavior.sql
git commit -m "feat: hold captain resources at T-72"
```

### Task 4: T-24 Consumption, Rematching and Safe Release

**Files:**
- Modify: `$migration_path` recorded in Task 1
- Modify: `tests/captain-resource-reservations.test.mjs`
- Modify: `supabase/tests/captain_resource_reservations_behavior.sql`
- Modify: `tests/t24-early-force-recovery.test.mjs`
- Modify: `tests/captain-today-contract.test.mjs`

**Interfaces:**
- Consumes: held reservations; `pace_v2.confirm_departure_t24(uuid,boolean,text)`; `pace_v2.process_departure_t24(uuid,text,boolean)`; existing captain assignment and completion functions.
- Produces: `pace_v2.confirm_reserved_captain(uuid,uuid) returns uuid`, `pace_v2.release_captain_reservations(uuid,text) returns integer`, exact T-24 reservation/assignment linkage, and lifecycle release hooks.

- [ ] **Step 1: Write failing T-24 and release tests**

Add executable cases proving:

- T-24 assignment captain equals the held reservation captain;
- deactivating that captain causes a deterministic rematch when another eligible captain exists;
- no alternative returns `at_risk_manual_review` / `T24_INSUFFICIENT_CAPTAINS` without inserting any confirmed allocations;
- failed vehicle/captain replacement leaves the old active reservation unchanged;
- cancellation and final duty completion release the active reservation;
- operator withdrawal, vehicle deactivation and route-offer deactivation release or rematch the affected provisional/held reservation without creating a confirmed gap;
- paired completion releases only after the final leg, not after Leg 1.

Add contract assertions for both helper signatures and revocations.

- [ ] **Step 2: Run RED verification**

Run: `node --test tests/captain-resource-reservations.test.mjs tests/t24-early-force-recovery.test.mjs tests/captain-today-contract.test.mjs`

Expected: FAIL because T-24 still calls `auto_assign_captain` and reservations have no release integration.

- [ ] **Step 3: Implement reservation-to-assignment confirmation**

`confirm_reserved_captain(p_confirmed_allocation_id,p_reservation_id)` validates, under row locks, that reservation, allocation, operator, vehicle, consideration and duty window agree; that the captain remains active and eligible; and that the reservation is `held_t72`. It inserts or reuses one active `captain_assignments` row for that captain, promotes the reservation to `confirmed_t24`, and links both IDs. Return the assignment UUID. Revoke from all client roles.

Replace the per-vehicle `auto_assign_captain(allocation_id)` call in `confirm_departure_t24` with the held reservation lookup and `confirm_reserved_captain`. Before inserting any confirmed allocation, `process_departure_t24` must call reconciliation under locks. If reconciliation cannot cover every surviving consideration, take the existing manual-review branch before any confirmation write.

- [ ] **Step 4: Implement safe release and replacement ordering**

`release_captain_reservations(p_departure_id,p_reason)` updates only active reservations for the departure, sets `released_at=now()` and records the supplied nonblank reason. Revoke from all client roles.

Call it from departure cancellation, zero-booking T-72 cancellation and closed-unrecorded reconciliation. Completion releases the confirmed reservation only when the final allocation leg is terminal. Booking cancellation uses Task 2 reconciliation instead of releasing a shared vehicle claim prematurely.

The protected operator-withdrawal function and the existing vehicle/route-offer eligibility triggers must reconcile affected future departures after their state change. Before T-24 they release or rematch provisional/held claims; after confirmation they retain the current assignment and force the existing authorised replacement/manual-review workflow rather than silently unstaffing the duty.

For authorised replacement, acquire and validate the replacement reservation first; update the assignment/allocation second; release the old reservation last. Any exception rolls the whole transaction back.

- [ ] **Step 5: Verify T-24 and full captain lifecycle**

Run: `node --test tests/captain-resource-reservations.test.mjs tests/t24-early-force-recovery.test.mjs tests/captain-today-contract.test.mjs tests/scheduler-history-lifecycle.test.mjs`

Expected: PASS.

Run the SQL fixture against preview. Expected: every assertion passes and transaction rolls back.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/*_captain_duty_reservations.sql tests/captain-resource-reservations.test.mjs tests/t24-early-force-recovery.test.mjs tests/captain-today-contract.test.mjs supabase/tests/captain_resource_reservations_behavior.sql
git commit -m "feat: confirm and release captain reservations"
```

### Task 5: Site Admin Resource-Conflict Evidence

**Files:**
- Modify: `$migration_path` recorded in Task 1
- Modify: `components/pages.tsx`
- Modify: `tests/vehicle-conflict-status.test.mjs`
- Modify: `components/journey-detail-consideration-status.test.tsx`

**Interfaces:**
- Consumes: reservation state/reason and conflicting departure identity from Tasks 1-4.
- Produces: additional `public.v2_admin_vehicle_considerations` columns `captain_resource_state`, `captain_resource_reason`, `captain_id_reserved`, and `captain_conflicting_departure_id`; Site Admin status copy and link.

- [ ] **Step 1: Write failing projection and component tests**

Extend the protected view contract to require the four columns without exposing captain contact information. Add component cases expecting:

```tsx
expect(screen.getByText('UNAVAILABLE — captain reserved elsewhere')).toBeInTheDocument();
expect(screen.getByRole('link',{name:/view conflicting journey/i})).toHaveAttribute(
  'href','/admin/journeys/conflicting-departure-id'
);
```

Add separate labels for `No eligible captain`, `Captain inactive`, `Captain no longer eligible`, and `Held for this journey`.

- [ ] **Step 2: Run RED verification**

Run: `node --test tests/vehicle-conflict-status.test.mjs && npx vitest run components/journey-detail-consideration-status.test.tsx`

Expected: FAIL because the view and component do not expose reservation evidence.

- [ ] **Step 3: Extend the protected projection**

Replace `public.v2_admin_vehicle_considerations` with the same explicit predecessor columns plus the four new columns. Resolve the conflicting departure from the active reservation that overlaps the current duty window. Keep the existing checked Site Admin helper and security posture; do not grant direct reservation-table access.

- [ ] **Step 4: Render operationally accurate status**

Extract the current inline consideration status logic into a small exported helper/component in `components/pages.tsx` or the existing local component file. Render the reason-specific label and journey link. `discarded_t72` without a captain reason retains the existing commercial T-72 label.

- [ ] **Step 5: Run GREEN verification**

Run: `node --test tests/vehicle-conflict-status.test.mjs && npx vitest run components/journey-detail-consideration-status.test.tsx`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/*_captain_duty_reservations.sql components/pages.tsx tests/vehicle-conflict-status.test.mjs components/journey-detail-consideration-status.test.tsx
git commit -m "feat: show captain resource conflicts to admins"
```

### Task 6: Safe Backfill, End-to-End Lifecycle and Release Evidence

**Files:**
- Modify: `$migration_path` recorded in Task 1
- Modify: `supabase/tests/captain_resource_reservations_behavior.sql`
- Create: `supabase/tests/captain_resource_reservations_end_to_end.sql`
- Create: `docs/release-evidence/2026-09-19-captain-resource-reservations.md`

**Interfaces:**
- Consumes: every interface from Tasks 1-5 and current live lifecycle functions.
- Produces: non-destructive migration backfill, one complete order-to-feedback rehearsal fixture, and release evidence for activation approval.

- [ ] **Step 1: Write the failing backfill and lifecycle fixture**

The end-to-end transaction creates:

1. an explicit paired return design;
2. two overlapping services competing for limited captains;
3. paid orders and whole-party allocations;
4. provisional reservations;
5. T-72 holds and one captain-conflict removal;
6. T-24 confirmed allocation/assignment;
7. operator/customer queued communications;
8. captain Leg 1 start/end and Leg 2 start/end;
9. completed departure and released reservation;
10. post-journey feedback notification scheduling.

Use pgTAP assertions on state and identities at every stage, then `rollback`. Include a backfill conflict fixture with two existing confirmed allocations sharing a captain and assert the migration records `captain_reservation_backfill_conflict` without changing either confirmed assignment.

- [ ] **Step 2: Run RED verification**

Run against preview: `psql "$SUPABASE_TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/captain_resource_reservations_end_to_end.sql`

Expected: FAIL because the migration has no backfill/alert procedure yet.

- [ ] **Step 3: Implement non-destructive backfill**

At migration end:

- validate confirmed allocations first and create `confirmed_t24` reservations only where the existing captain, eligibility and range are conflict-free;
- never replace or deactivate an existing confirmed assignment;
- create a high-priority `captain_reservation_backfill_conflict:<allocation_id>` alert for each conflict;
- reconcile future paid preliminary allocations into `provisional` or `held_t72` based on the current clock;
- leave unresolved departures/bookings `at_risk` with structured evidence;
- resolve the alert only after a later successful reconciliation.

The backfill must be idempotent and bounded to non-terminal future/open departures.

- [ ] **Step 4: Run the complete local verification suite**

Run: `npm test`

Expected: 0 failures; the database-only fixture may skip only when `SUPABASE_TEST_DATABASE_URL` is absent, and that skip must be recorded rather than described as database proof.

Run: `npm run build`

Expected: exit 0.

Run: `git diff --check`

Expected: no output and exit 0.

- [ ] **Step 5: Apply and verify on a Supabase preview branch**

Before creating a paid Supabase branch, call the Supabase cost tool and obtain the user's cost confirmation if required. Apply the CLI-generated migration to the preview project, then run both SQL fixtures. Query the reservation constraints, RLS state, grants, function grants and all four lifecycle states directly.

Expected: all fixtures pass; no anonymous/authenticated mutation path exists; no overlapping active reservations exist.

- [ ] **Step 6: Run Supabase advisors**

Run security and performance advisors on the preview project. Record every new finding introduced by this migration and remediate Critical/High findings before release. Existing unrelated findings must be listed separately and not misrepresented as introduced by this work.

- [ ] **Step 7: Write release evidence**

Record exact commits, commands, test counts, preview project ID, fixture results, advisor results, migration filename, rollback statement, and the unresolved operational status of the 20 September journey. State explicitly that production was not changed.

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/*_captain_duty_reservations.sql supabase/tests/captain_resource_reservations_behavior.sql supabase/tests/captain_resource_reservations_end_to_end.sql docs/release-evidence/2026-09-19-captain-resource-reservations.md
git commit -m "test: prove captain reservation lifecycle"
```

- [ ] **Step 9: Stop for production activation approval**

Present the preview evidence, migration/backfill impact, remaining live resource shortage and rollback procedure. Do not apply the migration to project `prvzgvkuefcflvmepuhd`, merge or deploy until the user explicitly approves activation.

## Production Activation Checklist (after separate approval)

- Apply the reviewed migration to `prvzgvkuefcflvmepuhd` with the Supabase migration tool.
- Re-run security and performance advisors.
- Verify all open future paid demands have either an active reservation or a high-priority operational alert.
- Verify 20 September remains explicitly at risk until real staffable capacity is supplied or customers are operationally resolved.
- Verify 21 September confirmed assignments have matching non-overlapping reservations.
- Deploy the application commit and verify the Site Admin conflict display.
- Observe one real hourly scheduler run and confirm every phase completes.
- Verify newly due T-24/operator/customer emails are claimed and sent or have explicit failure evidence.
