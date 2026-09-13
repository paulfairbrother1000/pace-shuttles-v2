# Site Admin Clock, Calendar & Triggers Design

**Date:** 2026-09-13

## Purpose

Add a standalone Site Admin mini-item that lets an administrator observe and control scheduled journey operations while Pace Shuttles is being tested end to end. Testing uses the existing regular journeys and accounts. The feature must not create, duplicate, or specially label test journeys.

The primary acceptance test is a genuine real-time T-24 execution: an administrator schedules a regular journey more than 24 hours ahead, leaves the scheduler enabled, and verifies that the existing scheduled-operations path queues and dispatches the journey-tomorrow email after the journey crosses its actual T-24 boundary.

## Navigation and access

- Add `Clock, Calendar & Triggers` as its own Site Admin navigation item and page.
- Use the existing Site Admin authorization boundary. Operators, captains, customers, anonymous users, and service accounts acting through the browser must not read or change these controls.
- Do not place the feature inside Captain, Journey, Communications, or general Configuration screens.

## Scheduler control

- Provide a single visible scheduler state: `On` or `Off`.
- The state applies to scheduled processing for all existing journeys. There is no separate test-journey scope.
- Turning the scheduler off requires a confirmation explaining that due communications and lifecycle events will wait.
- Turning it on requires a confirmation explaining that all overdue work will be processed immediately.
- Every state change records the acting Site Admin, previous state, new state, timestamp, and optional reason.
- The externally invoked scheduled-operations endpoint must check the persisted state before running journey scheduling or email dispatch. While off, it must return a successful, explicit `paused` result rather than an error.
- On an off-to-on transition, the system must request an immediate scheduled-operations run. The normal idempotency and uniqueness constraints remain authoritative, so overdue work is processed once and duplicates are not generated.

## Calendar and execution history

- Show scheduled operational events for existing journeys in chronological order.
- Each row shows journey, event type, intended due time, actual execution time when applicable, and status.
- Supported statuses are `Pending`, `Paused`, `Overdue`, `Processing`, `Sent`, and `Failed`.
- Supported event types initially include T-24 journey email and post-completion feedback request. Other existing scheduled operations may be shown when their due time and execution state can be represented reliably.
- Show timestamps in the journey country's configured timezone, with the timezone abbreviation or identifier visible.
- A failed item shows a safe failure reason and remains available for retry.
- Preserve the original due time when overdue work is later processed, and record the separate actual execution time.

## Manual triggers

- Provide Site Admin actions to run an individual supported communication or lifecycle event for a selected existing journey or booking.
- Require confirmation before execution.
- Mark every manually initiated execution as `Manual` in its durable audit data and in the UI.
- Manual execution must use the same validation, email construction, dispatch, audit, and idempotency paths as scheduled execution wherever possible.
- A manual result cannot be presented as evidence that the real scheduler ran successfully.
- Manual triggers must not bypass missing allocation, captain, vehicle, customer email, timezone, pickup-direction, payment, or journey-state prerequisites.

## Genuine T-24 proof

- The existing `v2_system_schedule_t24_journey_notifications` function remains the source of T-24 eligibility and content validation.
- The existing `/api/operations/run-scheduled` path remains the system entry point used by the real scheduler.
- Record enough execution evidence to show the journey departure time, calculated T-24 due time, scheduler invocation time, notification queued time, dispatch attempt time, and final delivery status.
- The UI must label a successful naturally scheduled execution `Scheduled` and a manually invoked one `Manual`.
- Acceptance requires observing an email generated after the real wall clock crosses T-24. Advancing a fake clock or pressing a manual trigger does not satisfy this test.

## Failure and restart behaviour

- While the scheduler is off, no scheduled journey operation or queued customer-email dispatch runs from the scheduler endpoint.
- Due items appear as `Overdue` rather than being discarded.
- When the scheduler is turned on, all overdue items are eligible for immediate processing in bounded batches until caught up.
- If automatic catch-up cannot be started, the state change remains recorded and the UI shows a clear failure with a retry action; it must not claim catch-up succeeded.
- Existing unique indexes and claim/send protections prevent duplicate T-24 and feedback messages across retries or overlapping invocations.

## Current pre-live operating constraint

Pace Shuttles is not yet in live customer use, so this version intentionally operates on regular journeys without additional test-recipient or test-journey restrictions. Before production launch, the unrestricted global switch and manual triggers must be reviewed and either protected by an explicit production lock or replaced with a safer operational control policy.

## Audit and observability

- Persist scheduler state changes and manual-trigger actions; do not rely on transient application logs.
- Display the most recent scheduler invocation, outcome, number of operations processed, number of emails claimed/sent/failed, and any safe error message.
- Never expose service-role credentials, cron secrets, raw provider responses containing sensitive data, or customer message bodies in the operational log.

## Verification

- Unit/source-contract tests cover Site Admin navigation, authorization, state transitions, paused endpoint behaviour, catch-up request behaviour, status calculation, timezone rendering, and manual-versus-scheduled labelling.
- SQL contract and behavioural tests cover Site Admin-only RPC access, durable audit records, legal transitions, overdue preservation, idempotency, and concurrency.
- Existing T-24, feedback, scheduled-operations, customer-email, captain, booking, and allocation regression suites must remain green.
- A production-schema rollback rehearsal must compile and exercise the migration without committing it.
- A browser smoke test must verify the page on mobile and desktop with an authenticated Site Admin.
- A real-time test must cross an actual T-24 boundary and record successful scheduled dispatch evidence.

## Non-goals

- Creating or labelling test journeys.
- Introducing a fake or accelerated application clock.
- Changing T-24 email copy.
- Replacing the external scheduler or email provider.
- Deploying, migrating, or changing production as part of design approval.
