# Scheduler History and Journey Lifecycle Design

## Purpose

Restore reliable real-clock scheduling, make each clock execution auditable in Site Admin, and remove past/open journey clutter without falsely describing journeys as completed or cancelled.

## Confirmed production findings

- Vercel invokes `/api/operations/run-scheduled` every hour as configured.
- Automatic executions succeeded at 13:00, 14:00, 15:00, and 16:00 UTC on 15 September 2026 after the first timeout repair.
- Executions from 17:00 UTC onward failed after about 125 seconds with `upstream request timeout`.
- The first ungenerated horizon date was Sunday 29 August 2027. Departure generation uses ISO weekday numbering, where Sunday is `7`, but `guard_service_departure_insert` validates with non-ISO numbering, where Sunday is `0`. The resulting deterministic validation error is incorrectly raised with retryable SQLSTATE `40001`, so the API layer retries until its upstream timeout.
- Eleven zero-booking journeys have passed T-72 but remain `under_consideration` or `at_risk`. Their completed T-72 records prevent the existing scheduler from evaluating them again.
- Two booked past journeys remain `confirmed` with no recorded actual departure or arrival. They cannot truthfully be marked `completed` or `cancelled`.

## Scheduler reliability

`guard_service_departure_insert` will use `extract(isodow ...)`, matching service generation and the stored `days_of_week` convention. Deterministic schedule-validation failures will no longer use the retryable serialization-failure SQLSTATE. This makes a genuine invalid schedule fail promptly and visibly rather than consuming the complete upstream timeout.

The hourly Vercel schedule remains `0 * * * *`. Successful verification requires observing a real Vercel-triggered production run after deployment; a manual database invocation is useful diagnostic evidence but is not release proof.

## T-72 and T-24 lifecycle

The lifecycle distinguishes two cases:

1. **Journey has zero qualifying bookings at T-72.** Cancel the journey immediately with the reason `Cancelled at T-72 — no bookings.` No vehicle remains under consideration and no T-24 allocation is attempted.
2. **Journey has one or more qualifying bookings at T-72.** Preserve the existing allocation design. Vehicles with no assigned parties at T-72 are discarded, while the vehicles still in play remain able to fill their vessels during the final 24 hours. Final vehicle and customer assignment remains a T-24 responsibility.

Qualifying bookings are the existing commercial lifecycle statuses `booked`, `at_risk`, and `confirmed`; unpaid or cancelled records do not keep a journey open.

The migration will reconcile the eleven already-processed zero-booking journeys that are past T-72 and still operationally open. It will cancel them using the same reason and record auditable allocation/scheduler evidence rather than silently updating status.

## Past journey closure

Add a terminal departure status named `closed_unrecorded`, displayed as **Closed — travel outcome unrecorded**. It is used only when a booked journey is past its expected completion window but neither a captain completion nor an explicit cancellation was recorded. This avoids asserting that travel occurred or did not occur.

Scheduled processing will close eligible stale journeys into this status after a bounded grace period following scheduled arrival. It will not overwrite `completed` or `cancelled`, and it will not alter financial settlement as though the journey completed. The two currently affected past confirmed journeys will be reconciled by the migration with an explicit closure reason.

Operational screens will default to current and future open journeys. A Past/closed filter will retain access to historical `completed`, `cancelled`, and `closed_unrecorded` journeys without allowing them to clutter live work.

## Execution history and drill-down

The existing Site Admin Clock and Calendar page will retain the latest-execution summary and add an execution-history section showing the most recent runs in reverse chronological order.

Each history row will show:

- overall status: running, paused, completed, or failed;
- source: scheduled, manual, or catch-up;
- requested, started, and finished times plus duration;
- the current or failed phase;
- counts for generated journeys, T-72 actions, T-24 actions, queued T-24 messages, queued feedback messages, claimed emails, sent emails, and failed emails;
- a concise impact statement when a phase fails;
- whether the incident remains unresolved or was resolved by a later successful scheduled/catch-up run.

Rows expand in place to show the ordered phases: journey operations, T-24 communications, feedback communications, and email delivery. The display uses named fields and plain-language descriptions rather than exposing raw JSON.

## Run evidence and failure handling

Scheduler run evidence will persist progress after each phase so a later failure does not erase completed work. The run will record `current_phase`, `failure_phase`, `impact_summary`, partial structured results, and resolution linkage.

Failure impact is derived from the failed phase:

- journey operations: that transaction did not commit; notification scheduling and email dispatch did not run;
- T-24 scheduling: journey operations committed, but T-24 messages were not queued in this run;
- feedback scheduling: earlier phases committed, but feedback messages were not queued;
- email delivery: messages remain queued/retryable, but were not delivered in this run.

When a later scheduled or catch-up run completes, it marks older unresolved failures resolved and records the successful run as the resolver. The UI will state what the successful run processed; it will not claim a particular customer communication was delivered unless the recorded results prove it.

## Security

Scheduler execution and progress functions remain service-role-only. Site Admin receives read-only history through protected `SECURITY DEFINER` functions that verify `is_site_admin()`. No scheduler tables or service functions become directly accessible to anonymous or general authenticated users.

## Testing and release proof

- Regression tests prove Sunday uses ISO weekday numbering and deterministic validation does not raise a retryable serialization error.
- Database contract tests prove zero-booking T-72 cancellation and preservation of the booked-party T-72/T-24 path.
- Tests prove stale booked journeys become `closed_unrecorded` without triggering completion settlement or feedback.
- Handler tests prove phase progress, partial results, impact, and resolution evidence survive failures.
- Component tests prove history summary, expandable phase detail, impact, and resolution rendering.
- Existing Node, Vitest, and production-build checks must pass.
- After deployment, verify the repaired Sunday generation path, the reconciled journey counts, the Site Admin history view, and at least one real automatic hourly execution.
