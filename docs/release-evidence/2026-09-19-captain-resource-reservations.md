# Captain Resource Reservations — Release Evidence

Date: 2026-09-19

Status: implementation and rollback-only production verification complete; production activation, merge, deployment and email dispatch have not been performed.

## Change identity

- Base: `ace3acb` (`origin/main`, Add T-24 return itinerary reminders)
- Design: `bf1eb8f`
- Plan: `e56ff14`
- Private reservation model: `05a57d8`
- Paid-demand reservation integration: `0c70ab3`
- T-72 holds and shortage handling: `43108a4`
- T-24 confirmation and lifecycle release: `1a7c79b`
- Site Admin conflict evidence: `1dbde23`
- Backfill and lifecycle rehearsal: `0765f06`
- Earlier release-evidence blocker record: `6965a8a`
- Branch: `codex/t72-captain-reservations`
- Migration: `supabase/migrations/20260919230203_captain_duty_reservations.sql`

## Local verification

| Command | Result |
| --- | --- |
| `npm test` | Node: 276 passed, 0 failed, 1 database-only skip; Vitest: 155 passed, 0 failed |
| `npm run build` | Exit 0; Next.js production build compiled and generated all pages |
| `git diff --check` | Exit 0; no whitespace errors |

The skipped Node test is the opt-in local PostgreSQL runner. The same SQL behavior was executed directly against the live production schema inside explicit rollback-only transactions, as recorded below.

## Rollback-only production rehearsal

Project `prvzgvkuefcflvmepuhd` was used only inside transactions that ended in `ROLLBACK`. No migration, test row, extension, allocation, alert or notification was committed, and no email dispatcher was invoked.

The 26 reservation pgTAP assertions passed in dependency-complete stages:

| Stage | Assertions | Result |
| --- | ---: | --- |
| Private table, range exclusion, paired duty window and client privacy | 4 | Passed |
| Paid allocation, companion reuse, overlapping demand rejection and cancellation release | 7 | Passed |
| T-72 distinct holds, shortage removal/alert/evidence/email gate and T-24 shortage stop | 8 | Passed |
| T-24 rematch, exact assignment identity and completion release | 3 | Passed |
| Legacy confirmed-assignment backfill conflict and idempotency | 4 | Passed |
| **Total** | **26** | **Passed** |

The full migration and one-time backfill also completed under rollback against current production data:

- 2 existing future confirmed allocations produced 2 `confirmed_t24` reservations;
- 0 confirmed-allocation reservation conflicts were found;
- 4 future open paid departures were reconciled;
- 2 departures remained short of captain coverage and produced explicit high-priority shortage evidence;
- 0 overlapping active captain reservations existed after reconciliation.

The catalog check inside the migrated transaction proved:

- the reservation table existed with RLS enabled;
- the captain/time-range exclusion constraint existed;
- `public`, `anon` and `authenticated` had no table read privilege;
- those client roles had no execute privilege on the private reservation/backfill helpers;
- the backfill produced exactly 2 confirmed reservations and no overlapping active ranges.

The final post-rollback check proved:

- `pace_v2.captain_duty_reservations` was absent;
- `vehicle_considerations.captain_resource_reason` was absent;
- `pace_v2.ux_departures_service_local_date` was present;
- the two temporarily disabled legacy resource triggers were enabled;
- the temporary `pgtap` extension was absent.

## Live-schema defects found and corrected

The rollback rehearsal found issues that local static tests could not expose:

1. Legacy captain assignments use `assigned_at`, not `created_at`; the backfill ordering now uses the live column.
2. The recursive matching CTE referenced its recursive term in two branches; it now uses one recursive branch with a lateral skip/captain option.
3. Deferred exclusion-constraint commands now use the schema-qualified constraint name.
4. The legacy-conflict fixture now selects a rowtype and captain scalar in separate statements and forces deferred checks at a diagnostic checkpoint.

Static contract assertions were added for the first three migration fixes, and the complete local suite was rerun after the corrections.

## Supabase advisor baseline

Security and performance advisors were run after rollback, so they describe the unchanged production baseline rather than the uncommitted reservation schema. No finding referenced `captain_duty_reservations` because that object correctly no longer existed.

- Security baseline: 1 `auth_users_exposed` error, 80 `security_definer_view` errors, 4 mutable-search-path warnings, 9 anonymous security-definer execute warnings, 127 authenticated security-definer execute warnings, plus informational RLS findings.
- Performance baseline: 163 unindexed foreign-key notices, 18 auth/RLS init-plan warnings, 17 unused-index notices, 13 multiple-permissive-policy warnings, 2 duplicate-index warnings and 1 Auth connection-strategy notice.

These are pre-existing project-wide findings, not findings introduced by this uncommitted migration. See the [Supabase database linter guidance](https://supabase.com/docs/guides/database/database-linter).

## Preview branch result

Preview branch `b9495cc2-510f-4147-9272-34ba203f637f` (project `jogsczyrijbfjlazeqra`) was deleted after proving that it had no `pace_v2` baseline. Production has no replayable migration history for the directly applied base schema, so a normal branch could not reproduce production. The approved rollback-only rehearsal supplied the missing live-schema compatibility evidence without committing changes.

## Backfill impact

The bounded one-time backfill:

- inspects only future, non-terminal confirmed work and future open paid work;
- creates a confirmed reservation only when the existing assigned captain is active, eligible, configured and conflict-free;
- never replaces or deactivates an existing confirmed captain assignment;
- records an unresolved high-severity alert when confirmed truth conflicts;
- reconciles preliminary paid work to `provisional` or `held_t72` based on the clock;
- leaves uncovered departures and bookings explicitly `at_risk` with structured evidence;
- is safe to rerun and resolves its alert only after the reservation later succeeds.

## Operational status at rehearsal

- The 20 September journey remained operationally at risk: the migration did not invent capacity or double-book a captain.
- The 21 September future confirmed allocations both had active, eligible configured captains and produced two conflict-free confirmed reservations during rehearsal.
- Two of the four future open paid departures still lacked enough eligible non-overlapping captain capacity and were explicitly surfaced as shortages.

## Rollback and activation gate

The rehearsal rollback is complete and production requires no cleanup.

For production activation, pause the scheduler, apply the reviewed migration, run both advisors again against the persisted schema, verify every future paid demand has a reservation or high-priority alert, deploy the matching application commit, resume/observe one scheduler run, and verify due communications have explicit sent or failed evidence.

Do not merge, deploy, apply the migration, run the committed backfill, or dispatch newly enabled communications until the user separately approves production activation.
