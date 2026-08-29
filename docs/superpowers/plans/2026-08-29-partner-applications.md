# Partner Applications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a V2-owned partner application workflow that promotes approved operators into the operator list and approved destinations into unpublished drafts that cannot go live until publication data is complete.

**Architecture:** Store anonymous applications in private `pace_v2` tables through a constrained public RPC, and expose review/promotion/publishing only through Site Admin-authorised RPCs and views. Reproduce the V1 form as a focused V2 component, add an Applications workspace to the existing admin shell, and make public destination visibility depend on an explicit publication timestamp plus active status.

**Tech Stack:** Next.js 15 App Router, React 19, TypeScript, Supabase/Postgres, Vitest, Node test runner

**Spec:** `docs/superpowers/specs/2026-08-29-partner-applications-design.md`

## Global Constraints

- The live V1 site and V1 database must remain untouched.
- New partner applications must be stored directly in Pace Shuttles V2.
- Preserve the V1 application inputs and initial mandatory-field behaviour.
- Approved operators must appear in the existing operator list but remain inactive/setup-required.
- Approved destinations must remain unpublished until every mandatory publication field passes database validation.
- Only Site Admin may review, approve, reject, publish or unpublish.
- All database functions must revoke default `PUBLIC` execution and grant only the minimum role.
- Production and the V2 Supabase project remain unchanged until all local and dry-run verification gates pass.

---

### Task 1: Application Schema and Anonymous Submission Contract

**Files:**
- Create: `supabase/migrations/20260829180000_partner_application_intake.sql`
- Create: `supabase/tests/partner_application_intake_contract.sql`
- Create: `supabase/tests/partner_application_intake_behavior.sql`

**Interfaces:**
- Consumes: existing `pace_v2.countries`, `pace_v2.vehicle_types`, `pace_v2.transport_type_places`, `pace_v2.destination_types`, `auth.uid()`.
- Produces: `pace_v2.partner_applications`, `pace_v2.partner_application_places`, `public.v2_public_partner_form_countries`, `public.v2_public_partner_form_transport_types`, `public.v2_public_partner_form_destination_types`, `public.v2_public_partner_form_places`, `public.v2_public_submit_partner_application(jsonb) returns uuid`.

- [ ] **Step 1: Create the migration using the Supabase CLI**

Run `npx supabase migration new partner_application_intake`, then rename the generated empty file to `supabase/migrations/20260829180000_partner_application_intake.sql` before adding SQL. Confirm `npx supabase --version` and `npx supabase migration list --local` first.

- [ ] **Step 2: Write failing SQL contract tests**

Assert that both new private tables exist with RLS enabled; application type is restricted to `operator|destination`; status is restricted to `new|under_review|approved|rejected`; only one of `operator_id` or `destination_id` may be populated consistently with application type; anonymous roles have SELECT only on the four lookup views; and anonymous has EXECUTE only on the submission function.

- [ ] **Step 3: Write failing anonymous behaviour tests**

Set the transaction role to `anon`, submit one valid operator and one valid destination, and assert both are created with `status='new'`, no review/promotion fields and cleaned text. Attempt to inject `status`, `admin_notes`, `operator_id`, `destination_id` and actor fields and assert none can be written. Assert invalid country/type/place relationships, missing organisation name, negative fleet size and overlong text fail without partial place rows. Keep email optional at application time to match V1; final destination publication separately requires email or telephone.

- [ ] **Step 4: Implement the private tables, lookup views and submission RPC**

Create explicit columns for every V1 input: application type/status, nullable country plus `other_country_text`, organisation/address/contact fields, website/social links, contact identity, years operating, operator transport type/fleet size/place selections, pickup/destination suggestions, destination type, description, admin notes, actor timestamps and promoted record IDs. Reuse the existing migrated V1 `pace_v2.destination_types` rows rather than creating another lookup. Validate UUID relationships inside the RPC, lock down table privileges, enable RLS and use a bounded `security definer` function with `set search_path=''`.

The public RPC contract is:

```sql
public.v2_public_submit_partner_application(p_application jsonb) returns uuid
```

It reads only allow-listed JSON keys and never dynamically constructs SQL.

- [ ] **Step 5: Run the intake SQL tests**

Run both SQL files inside rolled-back transactions against the development database. Expected: all assertions pass and no rows persist.

- [ ] **Step 6: Run Supabase advisors and commit**

Confirm the new objects introduce no unaudited security errors, then commit only the migration and two SQL tests with `feat: add V2 partner application intake`.

### Task 2: Site Admin Review and Atomic Promotion

**Files:**
- Create: `supabase/migrations/20260829181000_partner_application_review.sql`
- Create: `supabase/tests/partner_application_review_contract.sql`
- Create: `supabase/tests/partner_application_review_behavior.sql`

**Interfaces:**
- Consumes: `pace_v2.partner_applications`, `pace_v2.partner_application_places`, `pace_v2.is_site_admin()`, existing operator and destination tables.
- Produces: `public.v2_admin_partner_applications`, `public.v2_admin_update_partner_application(...)`, `public.v2_admin_set_partner_application_status(...)`, `public.v2_admin_approve_partner_application(uuid) returns jsonb`.

The promotion result contract is:

```json
{"application_id":"uuid","application_type":"operator|destination","operator_id":"uuid|null","destination_id":"uuid|null","status":"approved"}
```

- [ ] **Step 1: Create the migration using `npx supabase migration new partner_application_review` and rename it to the exact path above**

- [ ] **Step 2: Write failing review contract tests**

Assert ordinary authenticated users cannot read the view or execute mutation functions, every Site Admin RPC verifies `pace_v2.is_site_admin()`, approval locks the application row, and the view exposes every submitted field plus country/type names and promoted-record links.

- [ ] **Step 3: Write failing promotion behaviour tests**

Create Site Admin test context and prove: rejection creates no entity; reconsideration moves rejected to under review; operator approval creates one inactive operator and approved transport-type association; destination approval creates one inactive/unpublished destination; repeated approval returns the same linked ID; and a transaction error leaves the application unapproved with no partial entity.

- [ ] **Step 4: Implement review and promotion SQL**

Use an atomic approval RPC with `select ... for update`. For operators, copy application fields into `pace_v2.operators`, set `active=false`, create the selected `operator_vehicle_types` approval and link `operator_id`. For destinations, copy available data into `pace_v2.destinations`, set `active=false`, leave publication columns null and link `destination_id`. Record `reviewed_by`, `reviewed_at` and state changes in the same transaction.

- [ ] **Step 5: Run both review SQL tests and the existing SQL suite**

Expected: the new tests and every file in `supabase/tests/*.sql` pass.

- [ ] **Step 6: Commit**

Commit the migration and tests with `feat: add Site Admin partner application review`.

### Task 3: Destination Publication Gate

**Files:**
- Create: `supabase/migrations/20260829182000_destination_publication_gate.sql`
- Create: `supabase/tests/destination_publication_contract.sql`
- Create: `supabase/tests/destination_publication_behavior.sql`
- Modify: `lib/admin-geography.ts`
- Modify: `components/pages.tsx`

**Interfaces:**
- Consumes: existing destination save RPC, country hierarchy, destination editor and `v2_public_destinations` view.
- Produces: destination `published_at`, `published_by`, `public.v2_admin_set_destination_published(uuid, boolean)`, `validateDestinationPublication(form)` for immediate UI guidance.

The client validator contract is:

```ts
export type DestinationPublicationIssue = { field: string; message: string };
export function validateDestinationPublication(form: unknown, country?: { is_large?: boolean }): DestinationPublicationIssue[];
```

- [ ] **Step 1: Create the migration using `npx supabase migration new destination_publication_gate` and rename it to the exact path above**

- [ ] **Step 2: Write failing SQL tests for publication requirements**

Cover country, large-country region/locality, name, type, description, image, address/location, latitude bounds, longitude bounds, Google Maps URL, wet/dry arrival, arrival instructions and email-or-phone. Assert existing active destinations are backfilled as published, draft saves remain allowed, only published+active rows appear publicly, and unpublish removes without deleting.

- [ ] **Step 3: Implement the database publication model**

Add `published_at timestamptz` and `published_by uuid`, backfill current active destinations, update `v2_public_destinations` to require both active and published, and add the Site Admin-only publish/unpublish RPC with specific missing-field errors and coordinate validation.

- [ ] **Step 4: Write failing TypeScript tests for immediate validation**

Add `lib/admin-geography.test.ts` cases proving `validateDestinationPublication` returns the same missing fields and coordinate/URL rules as the database.

- [ ] **Step 5: Add explicit Save Draft, Publish and Unpublish controls**

Keep destination save permissive. In the Network Management destination editor, display Draft/Published status and missing publication requirements; call the publication RPC only from the explicit button and reload the destination list after success.

- [ ] **Step 6: Run focused and full tests, then commit**

Run `npx vitest run lib/admin-geography.test.ts`, both publication SQL tests and `npm test`. Commit with `feat: gate destination publication on complete details`.

### Task 4: V2 Public Partner Application Page

**Files:**
- Create: `app/partners/page.tsx`
- Create: `components/partner-application-form.tsx`
- Create: `lib/partner-application.ts`
- Create: `lib/partner-application.test.ts`
- Modify: `app/globals.css`

**Interfaces:**
- Consumes: public partner form lookup views and `v2_public_submit_partner_application`.
- Produces: `/partners`, `PartnerApplicationForm`, `buildPartnerApplicationPayload(input)`.

The public form contract is:

```ts
export type PartnerApplicationType = 'operator' | 'destination';
export type PartnerApplicationBuildResult =
  | { ok: true; payload: Record<string, unknown> }
  | { ok: false; errors: Record<string, string> };
export function buildPartnerApplicationPayload(input: Record<string, unknown>): PartnerApplicationBuildResult;
```

- [ ] **Step 1: Write failing payload and form tests**

Test operator/destination discriminator handling, V1-required fields, other-country text, operator-only transport/fleet/place values, destination-only type, common contact/social fields, numeric normalization and successful reference rendering.

- [ ] **Step 2: Implement the pure payload builder**

Define explicit `PartnerApplicationType`, form state and RPC payload types. Trim strings, preserve valid zero values, exclude fields belonging to the other application type and return field-specific validation errors.

- [ ] **Step 3: Reproduce the V1 form in a focused V2 component**

Keep the V1 wording and inputs, use the current Pace Shuttles public styles, load V2 lookups, submit through the V2 RPC and show the first eight characters of the returned UUID as the reference. Do not add final-publication-only destination requirements to initial submission.

- [ ] **Step 4: Add responsive and accessible styles**

Ensure labels are associated with inputs, type selectors expose pressed/selected state, submission errors use `role='alert'`, success receives focus, and the form works at the current mobile breakpoints.

- [ ] **Step 5: Run focused tests, type-check and commit**

Run `npx vitest run lib/partner-application.test.ts`, `npx tsc --noEmit --incremental false` and commit with `feat: add V2 partner application page`.

### Task 5: Homepage Partner Banner Link

**Files:**
- Modify: `components/customer-booking.tsx`
- Modify: `app/globals.css`
- Create: `tests/home-partner-banner.test.mjs`

**Interfaces:**
- Consumes: `/partners` route.
- Produces: an accessible homepage call-to-action linking to `/partners`.

- [ ] **Step 1: Write the failing banner test**

Assert the partner image is wrapped in a link to `/partners`, has accessible text for operators and destinations, and is keyboard reachable.

- [ ] **Step 2: Implement the linked banner**

Replace the image-only section with a `Link` containing the existing image plus concise overlay copy and a visible action such as `Partner with Pace Shuttles`.

- [ ] **Step 3: Run the focused and full suites, then commit**

Run `node --test tests/home-partner-banner.test.mjs`, `npm test` and commit with `feat: link homepage partner banner to applications`.

### Task 6: Site Admin Applications Workspace

**Files:**
- Create: `app/admin/applications/page.tsx`
- Create: `components/admin-partner-applications.tsx`
- Create: `lib/partner-application-admin.ts`
- Create: `lib/partner-application-admin.test.ts`
- Modify: `lib/data.ts`
- Modify: `components/ui.tsx`
- Modify: `app/globals.css`

**Interfaces:**
- Consumes: the Site Admin application view and review/promotion RPCs.
- Produces: `/admin/applications`, admin list/detail/filter/edit actions, links to `/admin/operators/[id]` or the associated destination in Network Management.

- [ ] **Step 1: Write failing state and rendering tests**

Test status labels/counts, type and search filters, complete detail mapping, editable review data, rejection without promotion, approval result routing, busy/error states and linked-record rendering.

- [ ] **Step 2: Add typed data access functions**

Add `loadPartnerApplications`, `adminUpdatePartnerApplication`, `adminSetPartnerApplicationStatus` and `adminApprovePartnerApplication` to `lib/data.ts`; keep payload construction and status-transition helpers in `lib/partner-application-admin.ts`.

- [ ] **Step 3: Build the Applications page and navigation**

Add `Applications` with a suitable icon after Operators in desktop navigation. Build a filterable table/cards view and a detail modal or panel with every V1 field, editable Site Admin notes and guarded workflow actions. On approval, display and link the created operator or destination draft.

- [ ] **Step 4: Verify responsive behaviour and commit**

Run focused Vitest tests, `npm test`, `npx tsc --noEmit --incremental false` and commit with `feat: add Site Admin application review workspace`.

### Task 7: Full Verification, Preview and Release Readiness

**Files:**
- Modify only if verification exposes a defect in files already owned by Tasks 1–6.

**Interfaces:**
- Consumes: all feature outputs.
- Produces: verified release candidate; no production mutation until these gates are green.

- [ ] **Step 1: Run every local gate sequentially**

Run `npm test`, `npx tsc --noEmit --incremental false` and `npm run build`. Expected: zero failures and all application routes compile.

- [ ] **Step 2: Dry-run and execute every SQL test**

Apply the three migrations in a rolled-back test transaction where supported, then run every `supabase/tests/*.sql` file. Confirm anonymous submission, customer/operator/captain isolation, Site Admin promotion, publication and existing contracts all pass.

- [ ] **Step 3: Run Supabase security review**

Check advisors and explicitly test table privileges, view predicates, function execution grants and plain-customer visibility. Resolve new findings before applying migrations.

- [ ] **Step 4: Apply migrations to Pace Shuttles V2 only**

Verify the project ref is `prvzgvkuefcflvmepuhd`, apply migrations in order, rerun all live SQL behaviour/contract tests and confirm the V1 project `bopvaaexicvdueidyvjd` is unchanged.

- [ ] **Step 5: Create and verify a preview deployment**

Push the feature branch, open a PR, wait for Vercel preview READY, then browser-test public operator and destination submissions, Site Admin review, rejection, operator approval/list visibility, destination approval/draft visibility, blocked incomplete publication, completed publication and public visibility. Remove synthetic test records through scoped cleanup SQL after verification.

- [ ] **Step 6: Review integration with the user and release**

Use the finishing-development-branch workflow. After the approved integration path, verify the production deployment, custom domain, homepage banner, `/partners`, admin access boundary and runtime error logs before reporting completion.
