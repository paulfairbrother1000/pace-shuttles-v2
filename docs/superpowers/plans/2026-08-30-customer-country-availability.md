# Customer Country Availability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show and sell only journeys backed by eligible vehicles while giving Site Admin an audited emergency country pause.

**Architecture:** Centralize public eligibility and pause enforcement in V2 Postgres views/functions, then derive the customer catalogue from that filtered contract. Add a protected Site Admin RPC and UI control for pause/restore, and apply the same country condition to the authenticated partner catalogue.

**Tech Stack:** Next.js 15, React, TypeScript, Supabase/Postgres, node:test, Vitest, Vercel.

**Spec:** `docs/superpowers/specs/2026-08-30-customer-country-availability-design.md`

## Global Constraints

- V2 production data only; no V1 database dependency.
- Existing bookings and operational visibility remain unchanged.
- Pause and restore both require a reason and are audit logged.
- Public discovery, quoting, quote intents, and partner catalogues must reject paused countries.
- Public catalogue items require at least one fully eligible future vehicle-backed departure.

---

### Task 1: Public catalogue filtering

**Files:**
- Modify: `lib/customer-booking-view.ts`
- Modify: `components/customer-booking.tsx`
- Test: `tests/customer-booking-view.test.mjs`

**Interfaces:**
- Produces: `availableCatalogue(countries, destinations, pickups, departures)` with filtered arrays.

- [ ] Write tests proving countries, destinations, and pickups without eligible departures are removed.
- [ ] Run the focused test and verify the new assertions fail.
- [ ] Implement the catalogue helper and use it in the booking UI.
- [ ] Remove unavailable-card labels and dead-end catalogue copy.
- [ ] Run the focused test and verify it passes.

### Task 2: Database eligibility and emergency pause

**Files:**
- Create: `supabase/migrations/20260830133000_customer_country_availability.sql`
- Create: `supabase/tests/customer_country_availability_contract.sql`
- Create: `supabase/tests/customer_country_availability_behavior.sql`

**Interfaces:**
- Produces: country pause columns, `country_customer_availability_audit`, `v2_admin_set_country_customer_availability(uuid,boolean,text)`, filtered `v2_public_departures`, guarded quote/search/intent functions, and paused-country partner exclusion.

- [ ] Write static and database contract tests for required columns, audit, grants, view eligibility, and public guards.
- [ ] Run the static test and verify it fails because the migration is absent.
- [ ] Implement the migration with indexed eligibility joins and explicit RPC privileges.
- [ ] Run the static test and verify it passes.
- [ ] Apply the migration to V2 and execute rollback-safe behavior probes.

### Task 3: Site Admin emergency control

**Files:**
- Modify: `lib/data.ts`
- Modify: `components/pages.tsx`
- Create: `tests/country-availability-admin.test.mjs`

**Interfaces:**
- Consumes: `v2_admin_set_country_customer_availability`.
- Produces: `adminSetCountryCustomerAvailability(countryId, paused, reason)` and country pause/restore controls.

- [ ] Write a UI contract test for reason-required pause and restore controls.
- [ ] Run it and verify it fails.
- [ ] Add the data wrapper and Site Admin country control with status and audit metadata.
- [ ] Run it and verify it passes.

### Task 4: Review, deployment, and end-to-end verification

**Files:**
- Modify only files required by review findings.

- [ ] Run the complete tests and production build.
- [ ] Request independent code review and resolve Critical/Important findings.
- [ ] Commit and publish the branch/PR, merge with the approved deployment workflow.
- [ ] Wait for Vercel production readiness.
- [ ] Verify browser, public API, partner API, database guard, and production logs.
