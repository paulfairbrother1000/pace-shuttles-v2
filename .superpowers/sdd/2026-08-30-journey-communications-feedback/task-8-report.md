# Task 8 Report: Journey Communications Release Readiness

Date: 2026-08-31

Branch: `feature/journey-communications-feedback`

Release commit: `10922783632723e76e151200d47af64156a62e40`

Status: `DONE_WITH_CONCERNS`

Task 8 adds release verification and operations documentation only. It does not
add production behavior, contact a remote database, deploy, push, open a pull
request, merge, or activate production.

## Delivered scope

- `tests/journey-communications-release.test.mjs` statically requires the full
  security fixture, deterministic lifecycle fixture, and server-only cron
  boundary.
- `supabase/tests/journey_communications_security_contract.sql` verifies the
  identity matrix, SECURITY DEFINER ACL/search-path contract, RLS/table grants,
  security-invoker projections, Site Admin predicates, and service-role-only
  scheduler/claim/mark interfaces inside a rollback-only transaction.
- `supabase/tests/journey_communications_end_to_end.sql` exercises one
  rollback-only two-party lifecycle across T-24, private messages, captain
  broadcast fan-out, actual completion + four hours, next-local-day 10:00
  feedback scheduling, feedback submission, and separated quality evidence.
- `README_CAPTAIN_INTERFACE.md` is now a captain operations, privacy,
  completion, incident, troubleshooting, and preview-verification runbook.
- `README_SERVICE_ACCESS.md` is now a server-only configuration, cron,
  service-role RPC, non-production test, observability, incident, activation,
  and rollback runbook.
- The implementation plan records local evidence and leaves every unexecuted or
  approval-gated release step open.

No Task 8 production migration was added. The SQL files are verification
fixtures and end with `rollback`.

## TDD evidence

The release contract was written before its SQL fixtures.

### RED

Command:

```bash
node --test tests/journey-communications-release.test.mjs
```

Observed before creating the fixtures:

```text
tests 3
pass 1
fail 2
```

The two failures named the missing required files:

```text
supabase/tests/journey_communications_security_contract.sql
supabase/tests/journey_communications_end_to_end.sql
```

### GREEN

Command:

```bash
node --test tests/journey-communications-release.test.mjs
```

Final result:

```text
tests 3
pass 3
fail 0
```

Final security self-review used a second focused RED/GREEN cycle. The release
contract first failed 1/3 checks until the transaction-local fixture table
explicitly granted `anon` read access to its test IDs; after the grant, all 3/3
checks passed. This ensures the anonymous RPC assertions fail at the protected
RPC boundary rather than during fixture-ID lookup.

## Local verification evidence

| Check | Result | Exact evidence |
| --- | --- | --- |
| Full test suite | Passed | `npm test`: 117/117 Node tests and 65/65 Vitest tests passed; 11/11 Vitest files passed |
| Production build | Passed | `npm run build`: Next.js 15.5.24 compiled, lint/type checks completed, and 24/24 static pages generated, including `/captain` and `/api/operations/run-scheduled` |
| Whitespace | Passed | `git diff --check`: exit 0, no output |
| Offline dependency audit | Passed with scope caveat | `npm audit --omit=dev --offline --audit-level=high`: exit 0, 0 vulnerabilities reported from locally available lock/cache data |
| Credential-shaped additions | Passed | Added-line scan found no credential-shaped additions |
| Generated files | Restored | `next-env.d.ts` SHA-256 `879741880b6ab48da99dcc06dcc674d381c9826137b0496bf7bb368f302de9fc`; `tsconfig.tsbuildinfo` SHA-256 `87867ac0a7dcf65940d0af30183a5494b94d0e93c67db93ddad7ea06f2b41c1f`; neither remains modified |
| Lint command | Unavailable as a result | `npm run lint`: exit 1 because `next lint` is deprecated and the repository has no ESLint configuration; Next.js opened its interactive configuration prompt, so no lint pass is claimed |
| PostgreSQL SQL suite | Not run | 26 `supabase/tests/*.sql` files are present, but `psql`, `pg_isready`, `postgres`, and Docker were unavailable |
| Supabase advisors | Not run | Supabase CLI and a deliberately linked non-production database context were unavailable |
| Browser E2E | Not run | No Chromium/Chrome/Playwright executable was available; the browser daemon was already retry-capped, so no further browser start was attempted |

The test suite emitted existing warnings for npm's unknown `http-proxy` config
and Node's typeless package parsing. The build emitted the existing multiple
lockfile/workspace-root warning. None changed the successful exit status.

The one-shot local capability check also found no `sqlfluff`, `pg_format`,
`pgsql-ast-parser`, or `sql-formatter`. No SQL runtime result is inferred from
the passing static release contract.

## SQL fixture prerequisites and execution

The repository does not contain a complete standalone definition and seed for
the pre-existing allocation, booking, route, captain, operator, and auth
schemas. The rollback-only Task 8 fixtures therefore deliberately select an
approved, seeded non-production confirmed allocation with:

- one active eligible assigned captain;
- two distinct paid, active party-leader bookings with valid email accounts;
- separate pure customer identities;
- separate assigned/other-captain, operator-only, and Site Admin identities;
- valid vehicle, route, pickup, destination, country, and timezone inputs.

Within the transaction, the end-to-end fixture makes exactly the selected two
bookings active/paid, cancels other allocation bookings, fixes scheduler inputs,
clears only their generated communications/feedback evidence, performs the
scenario, and rolls everything back. This produces deterministic fan-out while
preserving the external base-schema prerequisite.

Execute every SQL test only against the approved seeded non-production database:

```bash
for sql_file in supabase/tests/*.sql; do
  psql "$NON_PRODUCTION_DATABASE_URL" --set ON_ERROR_STOP=1 --file "$sql_file" || exit 1
done
```

Task 8 does not authorize obtaining, repurposing, or contacting a database URL.
No remote database was contacted.

## Security self-review

| Review focus | Evidence inspected | Conclusion / remaining gate |
| --- | --- | --- |
| Message isolation | Customer A/B owner views, distinct conversation IDs, assigned captain's two threads, other-captain/operator denials, Site Admin supervised view/reply | Static and SQL assertions are present; execute the fixture and repeat in preview browser identities |
| Recipient derivation | Broadcast accepts allocation/message/category/request ID; booking recipients and notifications are derived in PostgreSQL; cron accepts no recipient input | Boundary is preserved; verify preview queue/delivery records |
| Timezones | E2E fixes `America/Antigua` and asserts next local calendar day at exactly 10:00 | Deterministic assertion is present; execute it in PostgreSQL |
| Idempotency | T-24 and feedback schedulers run twice at the same boundary; broadcast uses a stable request UUID; counts remain per-booking | Static and SQL assertions are present; execute and inspect unique constraints/records |
| Allocation locking | Task 1-7 allocation/captain lifecycle fixtures remain in the full suite; Task 8 selects an existing eligible confirmed allocation | Full local tests pass; database suite and independent review remain open |
| Quality separation | E2E asserts operator/captain 60/40 effect `0.20`, zero operator effect for platform/location dimensions, and separate captain/pickup/destination/platform history | Static and SQL assertions are present; execute fixture and verify Site Admin preview |
| Service-role boundary | Catalog checks PUBLIC/anon revocation, fixed search paths, authenticated/service grants, internal guards; route reads only server env and exact bearer secret | Static checks pass; PostgreSQL ACL/advisor inspection remains open |

Self-review corrected three documentation/security-contract details before
final verification: T-24 opens the communication window but does not pre-create
every thread; `pace_v2.authorized_customer_booking_message_window(uuid)` is an
internal helper after the forward migration revokes authenticated execution;
and anonymous RPC checks can read transaction-local fixture IDs so their
expected permission error originates at the protected interface.

No independent reviewer was authorized for Task 8, so independent code and
security review is not claimed.

## Migration list for preview approval

Task 8 consumes the following Tasks 1-7 migrations in timestamp order:

1. `20260830220256_journey_communications_foundation.sql`
2. `20260830223023_t24_journey_notifications.sql`
3. `20260830234000_private_journey_messaging.sql`
4. `20260830234329_captain_journey_broadcasts.sql`
5. `20260831011259_journey_message_read_state.sql`
6. `20260831015350_journey_messaging_projection_hardening.sql`
7. `20260831022946_journey_feedback_quality.sql`
8. `20260831043354_admin_journey_quality_reporting.sql`
9. `20260831051600_admin_quality_paging_and_compatibility.sql`

Confirm the linked migration list against the approved non-production project
before applying anything. This report does not claim that any of these
migrations have been remotely applied.

## Release matrix

| Gate | Status | Evidence required to close |
| --- | --- | --- |
| Local release contract, Node/Vitest suite, build, diff, offline audit | Passed | Results above |
| All 26 PostgreSQL fixtures | Open | Execute with `ON_ERROR_STOP` against the approved seeded non-production database; retain exact output |
| Function grants, RLS/policies, exposed views, advisors, linked migrations | Open | Run Supabase advisors/migration list in the same approved context; inspect and resolve high/medium findings |
| Independent code/security review | Open | Review the complete Tasks 1-8 diff and resolve high/medium findings |
| Preview branch/PR/deployment/database migration | Controller approval gate | Push, open PR, deploy, and apply only after explicit approval |
| Browser role journey and rendered evidence | Open after preview | Verify all six identities, console, function logs, notification/email/broadcast delivery records, and operational alerts |
| Production activation approval | Explicit controller approval gate | Present PR, migration list, test totals, preview URLs/evidence, rollback, and caveats |
| Production migration/merge/deploy/live fixture | Explicit controller approval gate | Apply/merge/deploy only after activation approval; approve any controlled non-delivery fixture separately and prove transactional cleanup/zero residual rows |

## Exact external gates

1. Provide or authorize a deliberately linked, seeded non-production Supabase
   context, then execute all 26 SQL fixtures, advisors, migration list, function
   ACL, RLS/policy, and exposed-view inspection.
2. Authorize an independent code/security reviewer and resolve all high/medium
   findings.
3. Explicitly approve push, PR creation, preview deployment, and preview
   migration application; none occurred in Task 8.
4. In that preview, provide separate customer A, customer B, assigned captain,
   other captain, operator-only, and Site Admin identities; run the complete
   browser journey and inspect console, function logs, queue/email/broadcast
   delivery records, and operational alerts.
5. Explicitly approve production activation only after reviewing the PR,
   migrations, totals, preview evidence/URLs, rollback, and caveats.
6. Separately approve production migrations, merge, deployment, scheduler/live
   access verification, and any controlled non-delivery fixture. The current
   scheduler endpoint is mutating and has no read-only dry-run mode.

The branch and named worktree are intentionally preserved. No remote or live
side effects were performed.
