# Captain Today and General Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a mobile-first captain Today workspace with a grouped manifest, two independently timed journey legs and protected communications, while moving planning and history to General.

**Architecture:** Site Admin defines a return schedule on a journey design; one protected database operation atomically creates and permanently pairs the outbound and reverse departures. New protected captain projections group linked departures into a duty and existing per-departure timestamps provide independent leg evidence. Focused React components render Today and General without replacing the existing communications components or weakening server-side sequencing and access control.

**Tech Stack:** Next.js 15 App Router, React 19, TypeScript, Supabase/PostgreSQL, Vitest, Testing Library, Node test runner.

**Spec:** `docs/superpowers/specs/2026-09-02-captain-today-general-design.md`

## Global Constraints

- Today is calculated using the operating country's configured timezone, never the captain device timezone.
- Pairing comes only from Site Admin journey design and is never inferred from route, captain, vehicle or time similarity.
- Existing one-way journeys remain valid single-leg duties.
- A paired booking covers both legs and uses one shared manifest.
- Only the next valid leg action may succeed; the server records authoritative timestamps and repeated requests are idempotent.
- Existing protected communications windows, categories, request IDs, unread state and audit history remain intact.
- Existing booking, capacity, pricing, allocation, settlement, feedback and quality behaviour must not regress.
- Production database migration and activation are excluded until the user explicitly approves them after preview verification.

## File structure

- `supabase/migrations/20260902031500_captain_duties_and_return_legs.sql`: paired-departure schema, admin design RPCs, captain Today/manifest projections and leg-action RPCs.
- `supabase/tests/captain_duties_and_return_legs_contract.sql`: executable role, pairing, sequencing, timezone, manifest and compatibility evidence.
- `lib/captain-today.ts`: pure duty selection, state, party grouping and action-availability rules.
- `lib/captain-today.test.ts`: unit evidence for the pure rules.
- `lib/data.ts`: typed client wrappers for the new protected views and RPCs.
- `components/admin-service-editor.tsx`: Site Admin recurring outbound/return journey design form and save feedback.
- `components/captain-today.tsx`: safety-critical Today header, selector, manifest, legs and communications.
- `components/captain-today.test.tsx`: user-level Today interaction and failure-state tests.
- `components/captain-general.tsx`: possible, confirmed and completed non-today journeys.
- `components/captain-workspace-tabs.tsx`: URL-backed Today/General navigation.
- `components/captain-dashboard.tsx`: composition shell; existing messaging lifecycle remains here or is passed into focused child components.
- `components/captain-dashboard.test.tsx`: existing concurrency/message regression suite plus tab-boundary integration tests.
- `app/captain/page.tsx`: initial tab selection from the URL when required by the current page structure.
- `app/globals.css`: mobile-first captain workspace styling and touch targets.
- `tests/captain-today-contract.test.mjs`: static migration and client-boundary checks.

---

### Task 1: Paired journey design and additive database model

**Files:**
- Create: `supabase/migrations/20260902031500_captain_duties_and_return_legs.sql`
- Create: `supabase/tests/captain_duties_and_return_legs_contract.sql`
- Test: `tests/captain-today-contract.test.mjs`

**Interfaces:**
- Consumes: existing `pace_v2.departures`, routes, scheduled services, confirmed allocations and Site Admin predicates.
- Produces: `pace_v2.journey_pairs(id uuid, outbound_departure_id uuid, return_departure_id uuid, created_at timestamptz)` and `departures.journey_pair_id`, `departures.leg_number` with one-way-compatible nulls.

- [ ] **Step 1: Write failing structural tests**

Add assertions that the migration contains a unique pair identity, constrained leg numbers, two unique departure references, deferrable consistency enforcement, Site Admin-only mutation and no destructive rewrite of existing departures:

```js
test('return journeys are explicitly paired without changing one-way departures',()=>{
  const sql=readFileSync('supabase/migrations/20260902031500_captain_duties_and_return_legs.sql','utf8');
  assert.match(sql,/create table pace_v2\.journey_pairs/i);
  assert.match(sql,/check \(leg_number in \(1,2\)\)/i);
  assert.match(sql,/unique .*outbound_departure_id/i);
  assert.match(sql,/unique .*return_departure_id/i);
  assert.match(sql,/has_site_admin_access/i);
  assert.doesNotMatch(sql,/delete from pace_v2\.departures/i);
});
```

- [ ] **Step 2: Run the structural test and confirm it fails**

Run: `node --test tests/captain-today-contract.test.mjs`

Expected: FAIL because the migration does not exist.

- [ ] **Step 3: Implement the additive pairing schema**

Create `journey_pairs`, add nullable `journey_pair_id` and `leg_number` to departures, enforce `leg_number` is null for unpaired journeys and 1/2 for paired journeys, and enforce one outbound plus one return departure per pair. Add indexes on `(journey_pair_id,leg_number)` and departure date fields. Do not backfill guessed pairs.

- [ ] **Step 4: Add executable SQL pairing evidence**

The SQL fixture must create one legacy one-way departure and one admin-defined paired duty, then assert:

```sql
select tests.assert_eq((select count(*) from pace_v2.departures where journey_pair_id is null),1,'one-way departure retained');
select tests.assert_eq((select array_agg(leg_number order by leg_number) from pace_v2.departures where journey_pair_id=v_pair_id),array[1,2],'exactly two ordered legs');
```

Also assert duplicate leg 1, the same departure in two pairs, and non-admin pair creation fail.

- [ ] **Step 5: Run targeted tests**

Run: `node --test tests/captain-today-contract.test.mjs`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260902031500_captain_duties_and_return_legs.sql supabase/tests/captain_duties_and_return_legs_contract.sql tests/captain-today-contract.test.mjs
git commit -m "Add paired return journey model"
```

### Task 2: Atomic Site Admin journey-design save

**Files:**
- Modify: `supabase/migrations/20260902031500_captain_duties_and_return_legs.sql`
- Modify: `supabase/tests/captain_duties_and_return_legs_contract.sql`
- Modify: `lib/data.ts`
- Create: `components/admin-service-editor.tsx`
- Create: `components/admin-service-editor.test.tsx`
- Modify: `components/pages.tsx`

**Interfaces:**
- Consumes: outbound design fields plus `return_departure_local_time`, `return_duration_minutes` and `return_enabled`.
- Produces: `pace_v2.admin_save_paired_journey_design(...)` returning `journey_pair_id`, `outbound_departure_id`, `return_departure_id`, `updated_at`.

- [ ] **Step 1: Write failing database behaviour tests**

Cover atomic creation, reverse geography, shared operating date, return time, idempotent update and protected removal:

```sql
select * into v_saved from pace_v2.admin_save_paired_journey_design(
  p_service_id=>v_service_id,
  p_outbound_local_time=>'10:00',
  p_return_enabled=>true,
  p_return_local_time=>'16:00',
  p_return_duration_minutes=>30
);
```

Assert Leg 2 reverses pickup/destination, preserves the same pair ID on a repeated save, and removal fails after a booking or allocation exists.

- [ ] **Step 2: Run the preview SQL fixture and confirm the new assertions fail**

Run the repository's existing Supabase preview-test command documented in `package.json` or Task 8 release scripts.

Expected: FAIL because `admin_save_paired_journey_design` is absent.

- [ ] **Step 3: Implement the protected save function**

Use one transaction and row locks. Validate Site Admin, outbound service, reverse route compatibility, return after outbound arrival, timezone and positive duration. Insert/update both departures and pair together. Return a domain error when removal is blocked by bookings, allocations or operation evidence.

- [ ] **Step 4: Add typed client wrapper**

```ts
export type PairedJourneyDesignInput={
 serviceId:string; outboundLocalTime:string; returnEnabled:boolean;
 returnLocalTime:string|null; returnDurationMinutes:number|null;
};
export const adminSavePairedJourneyDesign=(input:PairedJourneyDesignInput)=>rpc('v2_admin_save_paired_journey_design',{
 p_service_id:input.serviceId,p_outbound_local_time:input.outboundLocalTime,
 p_return_enabled:input.returnEnabled,p_return_local_time:input.returnLocalTime,
 p_return_duration_minutes:input.returnDurationMinutes,
});
```

- [ ] **Step 5: Write failing editor tests**

Assert the form shows Return journey, return start time and duration; sends the exact typed payload; reports success; and preserves inputs with the database error when removal is refused.

- [ ] **Step 6: Implement the editor fields and save feedback**

Create `AdminServiceEditor` and compose it into the existing `ServiceScheduler` in `components/pages.tsx`. Use native time and number inputs. Disable return details unless enabled. Show inline validation and a persistent success/error message; do not use prompts.

- [ ] **Step 7: Run targeted SQL and UI tests**

Expected: all Task 2 assertions PASS.

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/20260902031500_captain_duties_and_return_legs.sql supabase/tests/captain_duties_and_return_legs_contract.sql lib/data.ts components/admin-service-editor.tsx components/admin-service-editor.test.tsx components/pages.tsx tests/captain-today-contract.test.mjs
git commit -m "Add return schedule to journey design"
```

### Task 3: Protected captain Today projections and leg actions

**Files:**
- Modify: `supabase/migrations/20260902031500_captain_duties_and_return_legs.sql`
- Modify: `supabase/tests/captain_duties_and_return_legs_contract.sql`
- Modify: `lib/data.ts`
- Modify: `tests/captain-today-contract.test.mjs`

**Interfaces:**
- Produces: `v2_captain_today_duties`, `v2_captain_today_manifest`, `v2_captain_start_leg(p_departure_id uuid)`, `v2_captain_end_leg(p_departure_id uuid,p_completion_state text,p_notes text,p_incident_summary text)`.
- `completion_state` is exactly `normal` or `incident`; incident requires a nonblank summary.

- [ ] **Step 1: Write failing access and sequencing tests**

Test assigned captain success and customer, other-captain and operator denial. Assert the sequence `start leg 1 → end leg 1 → start leg 2 → end leg 2`, reject all out-of-order calls, and return the existing timestamp for an exact retry.

- [ ] **Step 2: Run the SQL fixture and confirm failure at missing projections/functions**

- [ ] **Step 3: Implement the Today duty projection**

Return pair ID/duty ID, timezone, both leg IDs/names/times/timestamps, vehicle, operator, captain assignment and computed duty state. Include single-leg duties. Filter with each row's local date:

```sql
(scheduled_departure_ts at time zone country_timezone)::date = (now() at time zone country_timezone)::date
```

- [ ] **Step 4: Implement grouped manifest projection**

Return one row per booking party with `booking_id`, `lead_passenger_name`, `adult_count`, `child_count`, `infant_count`, `payment_status`, `special_requirements_present`, and a JSON passenger array containing only operationally required fields.

- [ ] **Step 5: Implement idempotent leg RPCs**

Lock both pair legs in leg order, verify the signed-in captain assignment and local operating day, enforce the next valid transition, use `clock_timestamp()` server-side, and never overwrite recorded evidence. Ending the final leg triggers existing journey/duty completion integration once; ending Leg 1 must not start settlement or feedback.

- [ ] **Step 6: Add client wrappers**

```ts
export async function loadCaptainTodayDuties(){return select('v2_captain_today_duties','first_scheduled_departure_ts',50)}
export async function loadCaptainTodayManifest(){return select('v2_captain_today_manifest','lead_passenger_name',500)}
export const captainStartLeg=(departureId:string)=>rpc('v2_captain_start_leg',{p_departure_id:departureId});
export const captainEndLeg=(departureId:string,state:'normal'|'incident',notes:string,summary:string)=>rpc('v2_captain_end_leg',{p_departure_id:departureId,p_completion_state:state,p_notes:notes,p_incident_summary:summary});
```

- [ ] **Step 7: Run SQL, contract and existing communication tests**

Expected: new tests PASS and existing security/messaging tests remain green.

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/20260902031500_captain_duties_and_return_legs.sql supabase/tests/captain_duties_and_return_legs_contract.sql lib/data.ts tests/captain-today-contract.test.mjs
git commit -m "Protect captain duty operations"
```

### Task 4: Pure captain Today presentation rules

**Files:**
- Create: `lib/captain-today.ts`
- Create: `lib/captain-today.test.ts`

**Interfaces:**
- Produces: `selectCurrentDuty(rows,now)`, `captainDutyState(duty)`, `nextLegAction(duty)`, `formatPartyComposition(party)`.

- [ ] **Step 1: Write failing unit tests**

```ts
expect(selectCurrentDuty([later,active,completed],now).id).toBe(active.id);
expect(nextLegAction(readyDuty)).toEqual({leg:1,action:'start'});
expect(nextLegAction(atDestinationDuty)).toEqual({leg:2,action:'start'});
expect(formatPartyComposition({adult_count:3,child_count:2,infant_count:1})).toBe('3 adults, 2 children, 1 infant');
```

Also cover one-way duties, completed duties, multiple countries/timezones and daylight-boundary dates.

- [ ] **Step 2: Run Vitest and confirm missing-module failure**

Run: `npx vitest run lib/captain-today.test.ts`

- [ ] **Step 3: Implement pure typed helpers**

Do not read `Date.now()` inside helpers; accept `now` explicitly. Prefer active, then earliest future today, then most recently completed today. Return no action for completed, non-today or invalid sequence data.

- [ ] **Step 4: Run targeted unit tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/captain-today.ts lib/captain-today.test.ts
git commit -m "Add captain duty presentation rules"
```

### Task 5: Mobile Today header, duty selector and manifest

**Files:**
- Create: `components/captain-today.tsx`
- Create: `components/captain-today.test.tsx`
- Modify: `app/globals.css`

**Interfaces:**
- Consumes: Today duty and grouped manifest rows plus a selected duty ID callback.
- Produces: `CaptainToday` with accessible sections `Manifest`, `Leg 1`, `Leg 2`, `Communications`.

- [ ] **Step 1: Write failing component tests**

Render two duties and assert the active duty is selected, title/pickup/vehicle are visible, later duty is compact, and no KPI/planning copy appears. Render a party and assert collapsed text `Michelle Fairbrother`, `3 adults, 2 children, 1 infant`, `PAID`; after tapping, assert all passenger names/categories and special requirements appear.

- [ ] **Step 2: Run targeted Vitest and confirm missing component failure**

- [ ] **Step 3: Implement header and selector**

Use semantic buttons and headings. Keep the active/next duty summary above the fold on a 390px viewport. Completed same-day duties remain selectable.

- [ ] **Step 4: Implement grouped manifest disclosure**

Use an accessible per-party disclosure button with `aria-expanded`; never render sensitive contact fields. Include unread count and a `Message this party` handoff.

- [ ] **Step 5: Add mobile-first styles**

Use a single column below 700px, minimum 48px touch targets, at least 12px separation between destructive/timing actions, sticky top tabs, high-contrast status text and no hover-only information.

- [ ] **Step 6: Run targeted component tests**

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add components/captain-today.tsx components/captain-today.test.tsx app/globals.css
git commit -m "Build mobile captain Today view"
```

### Task 6: Safe leg controls and completion panel

**Files:**
- Modify: `components/captain-today.tsx`
- Modify: `components/captain-today.test.tsx`
- Modify: `app/globals.css`

**Interfaces:**
- Consumes: `captainStartLeg`, `captainEndLeg`, `nextLegAction`.
- Produces: independent Leg 1/Leg 2 controls with preserved error drafts and authoritative refresh.

- [ ] **Step 1: Write failing interaction tests**

Assert only Start Leg 1 is initially enabled; resolving it exposes its timestamp and enables End Leg 1; ending Leg 1 enables Start Leg 2; completing Leg 2 completes the duty. Assert double taps invoke the action once.

- [ ] **Step 2: Write failing completion tests**

Assert End opens a panel with Normal selected, Incident reveals a required summary, a failed save retains notes/summary, and success closes the panel after refreshed timestamps arrive.

- [ ] **Step 3: Implement action state and confirmations**

Name confirmations with the exact leg route. Disable all transition controls while saving. Do not optimistically invent timestamps; reload duty data and show the returned server evidence.

- [ ] **Step 4: Implement completion panel**

Use radio buttons for `normal` and `incident`, optional notes, required incident summary, Cancel and `Record end time`. Keep the action reversible until the final submit; do not use chained browser prompts.

- [ ] **Step 5: Run targeted tests**

Expected: PASS including failure, stale-selection and double-submit cases.

- [ ] **Step 6: Commit**

```bash
git add components/captain-today.tsx components/captain-today.test.tsx app/globals.css
git commit -m "Add safe captain leg controls"
```

### Task 7: Today communications and General separation

**Files:**
- Create: `components/captain-general.tsx`
- Create: `components/captain-workspace-tabs.tsx`
- Modify: `components/captain-dashboard.tsx`
- Modify: `components/captain-dashboard.test.tsx`
- Modify: `app/captain/page.tsx`
- Modify: `app/globals.css`

**Interfaces:**
- Consumes: existing `JourneyConversation`, `CaptainBroadcastComposer`, protected loaders/actions and new `CaptainToday`.
- Produces: URL state `?tab=today|general`; Today party/all communications; General journey lists without operational buttons.

- [ ] **Step 1: Write failing tab-boundary tests**

Assert Today is default, `?tab=general` opens General, tab clicks update the URL, future journeys appear only in General, and no Start/End buttons exist in General.

- [ ] **Step 2: Write failing communication integration tests**

Assert `Message a party` opens the chosen party thread, `Message all` opens the broadcast composer, unread counts remain accurate, and changing duties cannot reuse another duty's conversation, message draft or request ID.

- [ ] **Step 3: Extract General without changing loader semantics**

Render Possible, Confirmed future and Completed/history groups. A today journey links to Today. Preserve the existing empty, error and loading states.

- [ ] **Step 4: Compose the Today communications section**

Reuse existing components and action functions. Pass explicit duty/allocation and conversation identities; retain the existing cancellation guards around stale asynchronous responses.

- [ ] **Step 5: Implement URL-backed tabs**

Use normal links or router replacement without a full authentication round trip. Mark the active tab with `aria-current` and preserve `today` as the default when the query is absent or invalid.

- [ ] **Step 6: Run captain integration tests**

Run: `npx vitest run components/captain-dashboard.test.tsx components/captain-today.test.tsx`

Expected: PASS including every pre-existing captain messaging concurrency test.

- [ ] **Step 7: Commit**

```bash
git add components/captain-general.tsx components/captain-workspace-tabs.tsx components/captain-dashboard.tsx components/captain-dashboard.test.tsx app/captain/page.tsx app/globals.css
git commit -m "Separate captain Today and General work"
```

### Task 8: Full local and preview release verification

**Files:**
- Modify only if evidence finds a defect: files from Tasks 1–7 and their tests.
- Create: `docs/release-evidence/2026-09-02-captain-today-general.md`

**Interfaces:**
- Consumes: complete feature branch.
- Produces: auditable pass/fail evidence and an explicit live-activation blocker.

- [ ] **Step 1: Run static checks and full automated suite**

```bash
git diff --check
npm test
npm run build
```

Record exact pass counts and build result.

- [ ] **Step 2: Apply migrations to an isolated preview database**

Apply the complete migration chain, run `captain_duties_and_return_legs_contract.sql`, existing Task 8 security fixtures and the deterministic booking/allocation scenario. Record project identity and migration hashes without secrets.

- [ ] **Step 3: Verify role security end to end**

As Site Admin, create a paired design. As the assigned captain, read only their Today duty/manifest and perform all four transitions. Prove customer, operator and a different captain cannot call the leg RPCs or read the protected manifest.

- [ ] **Step 4: Verify browser flows at mobile and desktop sizes**

At approximately 390×844 and 1440×900, verify Today defaults, active/next selection, grouped manifest drill-down, start/end confirmations, Normal/Incident panel, Message party/all, General separation and refresh persistence. Confirm touch targets are at least 48px and no horizontal overflow occurs.

- [ ] **Step 5: Verify regression boundaries**

Exercise an existing one-way captain journey, booking/checkout, allocation, T-24 communications, final-leg settlement trigger and post-duty feedback trigger. Confirm Leg 1 completion starts neither settlement nor feedback.

- [ ] **Step 6: Write release evidence**

Record each command/scenario, result, commit SHA, preview migration status, browser evidence and any blocker. End with:

```markdown
Live database migration: NOT APPLIED — awaiting explicit user approval.
Production deployment: NOT ACTIVATED — awaiting explicit user approval.
```

- [ ] **Step 7: Request independent review**

Use `superpowers:requesting-code-review` against the complete branch. Resolve findings by repeating the relevant failing test, minimal fix and verification cycle.

- [ ] **Step 8: Commit release evidence**

```bash
git add docs/release-evidence/2026-09-02-captain-today-general.md
git commit -m "Document captain workspace release evidence"
```

- [ ] **Step 9: Stop before activation**

Report the complete evidence and blockers. Do not apply the migration to the live Pace Shuttles database and do not merge/deploy production until the user explicitly approves both actions.
