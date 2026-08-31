# Partner Applications and Destination Publishing Design

## Purpose

Add a V2-owned partner application workflow for prospective Pace Shuttles operators and destinations. The homepage partner banner will lead to the proven V1 application form, reproduced in V2, while Site Admin gains a controlled review, approval, rejection and destination-publishing workflow.

V1 remains untouched. New applications are written directly to the Pace Shuttles V2 database.

## Goals

- Make the existing homepage partner banner actionable.
- Preserve the useful V1 operator and destination application inputs and wording.
- Let Site Admin review, annotate, edit, approve or reject applications.
- Add approved operators to the existing operator list.
- Convert approved destination applications into unpublished destination drafts.
- Prevent destinations from becoming customer-visible until all publication data is complete.
- Preserve an auditable link from every approved application to the created record.

## Non-goals

- Do not modify or write to the V1 application database.
- Do not activate an operator for allocation merely because its application is approved.
- Do not publish a destination merely because its application is approved.
- Do not create applicant accounts or implement applicant self-service tracking in this phase.
- Do not add email automation in this phase.

## User Experience

### Homepage and public application

The existing `partners-cta.jpg` banner at the bottom of the public booking experience becomes a link to `/partners` and has an accessible label inviting operators and destinations to partner with Pace Shuttles.

The V2 `/partners` page reproduces the current V1 experience:

- applicant selects Operator or Destination;
- country, organisation and contact details are collected;
- operators provide transport type, supported places, fleet size, pickup/destination suggestions and description;
- destinations provide destination type, pickup suggestions and description;
- common fields include address, telephone, mobile, email, website, social links, contact name and role, and years of operation;
- successful submission displays a short reference and review confirmation.

Only the V1 inputs are required during initial application. Fields needed for final destination publication may be supplied or corrected later by Site Admin.

### Site Admin applications workspace

Add an `Applications` item to Site Admin navigation and a dedicated `/admin/applications` page. The page provides:

- counts and filters for New, Under review, Approved and Rejected;
- application-type and free-text filters;
- received date, organisation, contact, country and application summary;
- a detail view containing every submitted field;
- editable review fields and Site Admin notes;
- actions to mark Under review, Approve or Reject;
- a link to the resulting operator or destination after approval.

Site Admin may correct or complete applicant-supplied data before approval. Every workflow mutation records the acting administrator and timestamp.

## Lifecycle

Applications use these states:

1. `new` — submitted and awaiting review.
2. `under_review` — Site Admin is assessing or completing the application.
3. `approved` — accepted and promoted to an operational draft record.
4. `rejected` — declined without creating an operational record.

The allowed transitions are:

- `new` to `under_review`, `approved` or `rejected`;
- `under_review` to `approved` or `rejected`;
- no transition out of `approved` in this phase;
- a rejected application may return to `under_review` if Site Admin decides to reconsider it.

Approval is atomic and idempotent. Repeated approval attempts return the previously created record instead of creating a duplicate.

## Operator Approval

Approving an operator application creates one record in `pace_v2.operators`, records its ID on the application and creates approved transport-type associations from the application.

The new operator:

- appears immediately in the existing Site Admin operator list;
- is created with `active = false` and a setup-required status/indicator;
- carries across organisation name, country, address, contact details, website, description and the selected transport type;
- does not participate in allocation until Site Admin completes setup and explicitly activates it through the existing operator editor.

No vehicles, captains, route offers, memberships or commission overrides are invented during approval.

## Destination Approval and Publishing

Approving a destination application creates one record in `pace_v2.destinations`, records its ID on the application and leaves the destination unpublished/inactive. It then appears in Network Management as a draft that Site Admin can edit.

Approval and publication are separate decisions.

Publication requires all of the following:

- country;
- region and locality when required by the selected country's hierarchy mode;
- destination name;
- destination type;
- description;
- uploaded picture;
- usable address/location information;
- latitude in the range -90 to 90;
- longitude in the range -180 to 180;
- valid Google Maps/directions URL;
- wet or dry arrival type;
- arrival instructions;
- at least one of contact email or telephone.

Site Admin may save incomplete destination drafts. The Publish action validates the complete record in the database transaction. Missing or invalid fields are returned as specific errors and the destination remains unpublished.

Unpublishing is supported through the same control so Site Admin can immediately remove a destination from the public catalogue without deleting it.

The existing public destination view exposes published destinations only. Draft, rejected and unpublished records never appear in the customer destination tiles, filters or journey details.

## Data Model

Create `pace_v2.partner_applications` with:

- identity and audit columns: `id`, `created_at`, `updated_at`, `submitted_by`, `reviewed_by`, `reviewed_at`;
- lifecycle: `application_type`, `status`, `admin_notes`;
- country and organisation/contact fields preserved from V1;
- operator inputs: transport type, fleet size, supported-place selections and suggestions;
- destination inputs: destination type and pickup suggestions;
- common description and social links;
- promotion links: nullable `operator_id` and `destination_id` with constraints matching application type.

Create `pace_v2.partner_application_places` for the V1 supported-place selections.

Use a destination `published_at` timestamp and `published_by` administrator reference in addition to the existing `active` flag. `published_at is not null and active = true` defines customer visibility. Existing active destinations are backfilled as published during migration so the current catalogue does not disappear.

## Interfaces and Transactions

Public lookup views expose only the active countries, transport types, destination types/values and supported places needed by the form.

Public submission uses one narrowly scoped database function. It validates lengths, UUID ownership/relationships, numeric bounds and application-type-specific fields. It inserts only application data and cannot set workflow, review, promotion or publication fields.

Authenticated Site Admin functions provide:

- list/read applications;
- update reviewable application data and notes;
- change review status;
- approve and promote an application atomically;
- publish or unpublish a destination after database-level completeness validation.

Approval locks the application row, verifies Site Admin access, checks the current state and writes the created entity and application link in one transaction.

## Security

- Application tables live in the non-exposed `pace_v2` schema with RLS enabled as defence in depth.
- Anonymous users receive no direct table access.
- The public submission function is the only anonymous write path and accepts no status, notes, approval, linked-record or publishing fields.
- Public form lookup views are read-only and contain no private contact/application information.
- Review, edit, approval, rejection and publication functions require `pace_v2.is_site_admin()`.
- Site Admin views are not readable by ordinary customer, operator or captain accounts.
- Image uploads for destination drafts remain Site Admin-only and use the existing geography image path.
- All new functions revoke default `PUBLIC` execution before granting the minimum required role.

## Error Handling

- Client-side validation gives immediate feedback for the V1 mandatory application fields.
- Database validation is authoritative and returns field-specific errors.
- A failed submission does not create a partial application or supported-place rows.
- A failed approval creates neither a partial operator/destination nor an approved status.
- A failed publish leaves the destination unpublished and identifies every missing mandatory field where practical.
- Duplicate submission is not automatically merged; Site Admin can reject duplicates. Approval itself is idempotent.

## Testing and Acceptance Criteria

Automated tests must prove:

- homepage banner links accessibly to `/partners`;
- V1 operator and destination inputs are present in V2;
- valid anonymous applications succeed and privileged-field injection is ignored/rejected;
- invalid lookup IDs and cross-type inputs fail;
- ordinary authenticated users cannot list or mutate applications;
- Site Admin can edit, move to Under review and reject without creating an entity;
- operator approval creates exactly one inactive operator that appears in the operator list;
- destination approval creates exactly one unpublished destination draft;
- repeated approval does not duplicate either entity;
- incomplete destinations can be saved but cannot be published;
- every mandatory field and coordinate bound is enforced at publication;
- a complete destination can be published and appears in the public destination view;
- unpublishing removes it from the public view without deleting it;
- existing published destinations remain customer-visible after migration;
- application-to-entity links and actor/timestamp audit fields are retained.

Before deployment, run the complete application test suite, TypeScript check, production build, SQL contract/behaviour tests, Supabase security advisors, role-isolation checks and production browser smoke tests.
