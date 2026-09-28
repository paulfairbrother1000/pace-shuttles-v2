# End-to-end readiness recovery — design

Date: 28 September 2026

## Intent and scope

Make existing Pace Shuttles journeys usable for a real end-to-end test, including accurate lifecycle closure, captain access, allocations, customer communications, scheduler monitoring and post-travel feedback. Preserve the approved T-72 and T-24 allocation policy, party cohesion and existing regular journeys. Do not fabricate completed travel, send historical customer communications indiscriminately or create test journeys.

## Findings that shape the design

- Twenty expired, non-commercial paired return departures remain scheduled. The closure RPC handles empty **commercial** departures and non-commercial returns only when a paired departure has an active booking. All twenty have no qualifying paired bookings, so neither branch applies.
- The pending `BOOKING_CONFIRMED`, `PAYMENT_RECEIVED`, `T72_AT_RISK`, `T24_CUSTOMER_ACTION_REQUIRED`, `JOURNEY_REMINDER_24H` and `JOURNEY_REMINDER_3H` rows on the 24 September departure are all `in_app` notifications. Its separate `email` booking-confirmation row is `sent`. An in-app pending row does not prove an unsent email.
- The existing Vercel hourly cron has a missing invocation on 24 September at 05:00 Antigua time. A route that is not called cannot record its own failure or send its own alert.
- Barefoot captains Dave Dryland and David Birdshit exist without sign-in links. The existing admin linking RPC requires an actual signed-up Supabase Auth user; only the approved shared test email may map to multiple captains.

## Journey lifecycle

Extend the scheduled reconciliation query for non-commercial paired returns. After the existing 24-hour outcome grace period, cancel an empty return when neither leg has a qualifying booking; record a reason that identifies the empty paired return. If a paired leg has a qualifying booking and no recorded arrival, retain `closed_unrecorded` and its explicit uncertainty. Preserve completed, cancelled and active journeys outside the grace window. Reconcile the existing twenty only after the new rule has been tested against the exact IDs and their bookings; retain an audit of before/after state. Check that the admin operational filter hides terminal rows but retains historical access.

## Allocation and communications

Trace the 21 and 24 September failures through booking, vehicle consideration, T-72 job, T-24 job, captain availability and notification scheduling evidence. Reproduce the first confirmed root cause in a database test before a narrowly scoped fix. Respect minimum seats/revenue, no split parties, no overlapping captain/vehicle, T-72 discard, and T-24 consolidation. Report insufficient eligible capacity as at-risk with a clear reason rather than asserting an allocation. Separately test the *email channel* and its due-email claim/dispatch pipeline. Pending in-app rows must remain accessible through the in-app UI or receive an explicit delivery semantics change; they must not be reclassified as unsent emails. Avoid replaying expired itinerary emails after travel.

## Captain sign-in

Use the existing site-admin captain-link flow. Dave and David receive distinct Auth accounts and their own verified email addresses if available; if only the previously approved shared testing mailbox is available, link both to that mailbox and rely on the existing identity selector, explicitly limiting this to the existing test exception. Do not invent their personal addresses or passwords. Verify each captain's operator, active status, linked user, dashboard selection and exclusion of conflicting duties. A real OTP delivery and captain UI sign-in remain a live check by the holder of the mailbox.

## Missing cron detection

Add an independently scheduled, authenticated watchdog route that checks the latest *scheduled* run against the hourly schedule with a grace period. It records each missing slot idempotently with expected slot, observed evidence, impact and eventual recovery, and sends the site admin an alert through the existing alert delivery mechanism. A missing slot must appear in the Site Admin schedule history even though no ordinary scheduler run was created. Use a separate Vercel cron invocation so failure of the main scheduled endpoint is detectable; document that a common Vercel-wide outage still needs external monitoring. The watchdog must not start duplicate journey processing or send customer messages.

## Validation and rollout

Add focused tests first for empty and booked paired returns, missed-run detection/deduplication/recovery, access boundaries and the demonstrated allocation failure. Run existing scheduler, allocation, captain and email tests plus build. Stage the database migration before deploying compatible application code; verify security grants and the migration history. Check the watchdog and scheduler history in production and ensure only intended old return legs change status. Verify captain access with the account holder. For the 9 October Jolly Harbour → Boom journey, verify the T-72 decision on 6 October at 10:30 Antigua time, T-24 on 8 October at 10:30, real travel on 9 October, then four-hour feedback, NPS and quality evidence. If the minimum of four seats is not met, treat an at-risk/cancellation result as a valid policy outcome rather than claiming a completed voyage.

## Completion criteria

No stale past paired return legs remain open; booked journeys either obtain valid resources or a reasoned at-risk outcome; captain identities are operable; due emails are proved separately from in-app notices; missing hourly invocations surface in history and admin alerts; and the next live journey's phase evidence is documented as each event occurs. Future real-time phases cannot be marked complete before their actual trigger.
