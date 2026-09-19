# Captain-Pending Customer Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure paid customers receive useful T-24 journey details even when final captain coverage is incomplete, while keeping the journey at risk until real captains are assigned.

**Architecture:** Add a dedicated `journey_captain_pending` notification that carries structured journey and vehicle metadata and renders through the existing email dispatcher. Queue it from the T-24 scheduler for captain-related manual-review cases, without creating a captain record or confirmed allocation. The normal `journey_tomorrow` notification remains independent and may be sent later after a real captain is assigned.

**Tech Stack:** Next.js 15, TypeScript, Node test runner, PostgreSQL/Supabase, Resend, Vercel.

**Spec:** Approved in this conversation on 19 September 2026.

## Global Constraints

- `Captain: To be confirmed` is customer-facing fallback copy, not an operational captain identity.
- Departure and bookings remain `at_risk` until real captain coverage is complete.
- Every paid active booking gets at most one captain-pending email per departure.
- A later final `journey_tomorrow` email remains possible after real captain assignment.
- Existing real-captain constraints must not be weakened.

## Review Focus

- Captain shortage with valid preliminary vehicle details queues the informative fallback.
- Missing vehicle details remains an alert and does not invent a vehicle.
- Duplicate scheduler runs do not duplicate pending emails.
- A pending email does not suppress the later final confirmation.
- Customer copy does not claim that an unconfirmed captain can receive day-of-travel messages.

---

### Task 1: Captain-Pending Email Content

**Files:**
- Modify: `lib/journey-email-content.ts`
- Test: `tests/journey-email-content.test.mjs`

**Interfaces:**
- Consumes: structured customer, route, local time, vehicle, directions and wet-arrival fields.
- Produces: `buildCaptainPendingJourneyEmail(input): {subject:string; text:string}`.

- [ ] Write a failing test for exact fallback copy, vehicle type/name, date, time, route, directions and `Captain: To be confirmed`.
- [ ] Run the focused test and confirm it fails because the builder is absent.
- [ ] Add the minimal builder without changing the confirmed-captain email.
- [ ] Run the focused test and confirm it passes.

### Task 2: Dispatcher Integration

**Files:**
- Modify: `lib/customer-email.ts`
- Test: `tests/customer-email.test.mjs`

**Interfaces:**
- Consumes: `journey_captain_pending` rows with structured metadata.
- Produces: canonical Resend subject, text and HTML using the new builder.

- [ ] Write a failing dispatcher test asserting structured metadata overrides stored fallback text.
- [ ] Run the focused test and confirm it fails for the expected reason.
- [ ] Route the new template through `buildCaptainPendingJourneyEmail`.
- [ ] Run the focused test and confirm it passes.

### Task 3: T-24 Queue Safety Catch

**Files:**
- Modify: `supabase/migrations/20260919191150_captain_pending_customer_notifications.sql`
- Create: `supabase/tests/captain_pending_customer_notifications_behavior.sql`
- Test: `tests/captain-pending-notification-contract.test.mjs`

**Interfaces:**
- Consumes: paid active bookings, preliminary booking allocations, vehicle considerations and T-24 captain-shortage state.
- Produces: one `journey_captain_pending` notification per booking/departure plus the existing unresolved high-priority operational alert.

- [ ] Write contract and behaviour tests for fallback queueing, deduplication and later final-notification independence.
- [ ] Run the contract test and confirm it fails before migration implementation.
- [ ] Add the partial unique index and replace the T-24 scheduling function with safe pending handling.
- [ ] Re-run the contract test and confirm it passes.

### Task 4: Live Journey Processing and Release

**Files:**
- Modify: migration history and deployed application through the established Supabase/Vercel release paths.

**Interfaces:**
- Consumes: departure `e65269ee-0ced-400a-b99d-5627a2b83a0a` and its seven paid bookings.
- Produces: seven queued fallback notification records, provider delivery references after dispatch, and an unchanged at-risk operational status.

- [ ] Run all tests and the production build.
- [ ] Apply the reviewed migration and run Supabase security/performance advisors.
- [ ] Queue the seven current-trip notifications and trigger the established email dispatcher.
- [ ] Verify seven distinct booking notifications, their statuses/provider references, and the retained at-risk state.
- [ ] Commit, push, deploy, and verify the production deployment and runtime errors.

