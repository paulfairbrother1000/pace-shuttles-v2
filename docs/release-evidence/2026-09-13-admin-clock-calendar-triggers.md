# Clock, Calendar & Triggers release evidence

## Scope

Feature branch `feature/admin-clock-calendar` adds persisted scheduler state, immutable state-change audit, scheduler-run evidence, pause-aware scheduled operations, a Site Admin calendar projection, protected administrative actions, and the standalone `/admin/clock-calendar` interface. It also fixes the pre-existing async captain-conversation selection race exposed by the baseline suite.

No push, merge, deployment, production migration, or production data change was performed.

## Automated evidence

- `node --test tests/admin-scheduler-control.test.mjs tests/admin-scheduler-handler.test.mjs tests/scheduled-operations-route.test.mjs`: 16/16 passed.
- `npx vitest run components/admin-clock-calendar.test.tsx lib/admin-scheduler.test.ts components/auth.test.tsx`: 7/7 passed.
- Focused captain regression: `npx vitest run components/captain-dashboard.test.tsx`: 25/25 passed.
- Full suite: `npm test`: 209/209 Node tests and 141/141 Vitest tests passed.
- Production bundle: `npm run build`: completed successfully and emitted `/admin/clock-calendar` plus `/api/admin/scheduler`.

## Open verification gates

- Database credentials are unavailable in this worktree, so the new migration and SQL fixtures have not been compiled or executed against the production schema inside a rollback transaction.
- No authenticated Site Admin browser session or preview deployment is available, so rendered checks at 390x844 and 1440x900 remain pending.
- The real-time T-24 acceptance test necessarily remains pending until the migration and application are activated in an approved environment and a regular journey crosses its actual T-24 boundary.

## Real-time T-24 acceptance procedure

1. Select an existing regular journey scheduled slightly more than 24 hours ahead.
2. Make a paid booking using an email inbox available to the tester.
3. Confirm a vehicle and an eligible assigned captain with first and last name.
4. Confirm the pickup has a valid Google Maps directions URL and the country has a valid timezone.
5. Leave the scheduler `On` and record the calendar's T-24 due time.
6. After the real wall clock crosses the due time, record the scheduler invocation, notification creation, dispatch attempt, provider result, and received email time.
7. Confirm the calendar labels the execution `Scheduled`, not `Manual`, and that a later scheduler invocation does not create or send a duplicate.

## Activation gate

Do not apply `20260913120000_admin_scheduler_control.sql`, push, merge, or deploy until the rollback rehearsal and authenticated preview checks pass and Paul explicitly approves activation.
