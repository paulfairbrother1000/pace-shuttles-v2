# V1 Image Library Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Copy the complete Pace Shuttles V1 image library into V2 without changing V1, retain every object path, and make V2 geography administration use the V2 copies.

**Architecture:** Inventory V1 Storage as the immutable source, provision the protected public `images` bucket in V2, and copy objects byte-for-byte through a temporary migration worker authenticated with V2's server-side service role. Verify object paths, sizes, MIME types and counts before disabling the worker. Reconcile only V2 database URLs; V1 remains untouched as rollback source.

**Tech Stack:** Supabase Storage, Supabase Edge Functions, PostgreSQL, TypeScript, Next.js.

**Spec:** Approved conversation design: preserve the V1 `images` bucket hierarchy and move all images to V2 before V1 is retired.

## Global Constraints

- Never delete, overwrite or update V1 objects or records.
- Keep the existing object paths under `countries/`, `pickup-points/`, `destinations/`, `vehicles/`, `operators/`, `staff/` and `transport-types/`.
- The V2 `images` bucket remains public for customer-facing pictures; uploads remain restricted to authorized Site Admin users.
- Do not expose a service-role or secret key to browser code, logs or the repository.
- Copy with `upsert: false`; report any path collision instead of replacing it.
- Disable the temporary migration worker after verification.

---

### Task 1: Immutable Source Inventory

**Files:**
- No repository changes.

**Interfaces:**
- Consumes: V1 `storage.buckets` and `storage.objects` metadata.
- Produces: Source manifest containing object path, MIME type and byte size.

- [ ] Query V1 for all `images` bucket objects ordered by path.
- [ ] Record total count and byte size by top-level folder.
- [ ] Confirm V2 target state and identify any existing path collisions.

### Task 2: Provision the V2 Geography Editor and Storage Contract

**Files:**
- Use: `supabase/migrations/20260827202249_restore_admin_geography_editing.sql`
- Verify: `supabase/tests/admin_geography_editor_contract.sql`

**Interfaces:**
- Consumes: Existing V2 `pace_v2` schema.
- Produces: Public `images` bucket, Site Admin policies and geography save RPCs.

- [ ] Apply the committed migration to V2 once.
- [ ] Run the SQL contract checks.
- [ ] Query the resulting bucket, policies, RPC grants and security-invoker view.

### Task 3: Copy Objects Without Overwriting

**Files:**
- No persistent migration credential or worker source is committed.

**Interfaces:**
- Consumes: V1 public object URLs and the Task 1 manifest.
- Produces: Identically named V2 Storage objects.

- [ ] Deploy a temporary server-side worker with a one-time random authorization token.
- [ ] Submit bounded batches of source paths, MIME types and expected sizes.
- [ ] Download each public V1 object and upload it to V2 with `upsert: false`.
- [ ] Record copied, collided and failed paths for every batch.

### Task 4: Reconcile V2 URLs and Verify the Cutover

**Files:**
- Modify only if required: a generated Supabase migration for deterministic V1-to-V2 URL replacement.
- Test only if required: a SQL URL reconciliation contract.

**Interfaces:**
- Consumes: Verified V2 object manifest and V2 geography records.
- Produces: V2 records whose image URLs reference the V2 project.

- [ ] Compare V1 and V2 path/count/size manifests and require zero missing or extra copied objects.
- [ ] Find V2 `picture_url` values that still reference the V1 project.
- [ ] Write and verify a failing SQL contract before adding any URL rewrite migration.
- [ ] Replace only the known V1 public Storage URL prefix with the V2 prefix.
- [ ] Re-run manifest, URL, automated test and production-build verification.
- [ ] Redeploy the temporary worker as an inert JWT-protected endpoint.
- [ ] Run Supabase security and performance advisors and report any pre-existing findings separately.

