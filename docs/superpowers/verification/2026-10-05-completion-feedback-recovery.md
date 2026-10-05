# Completion/feedback recovery — verification and release gate

Verified on 5 October 2026. Production remains unchanged; the four forward-only recovery migrations are ready on the recovery branch.

## Implemented

- Retain completed outbound passenger parties on paired returns; genuine multi-boat final completion updates both leg statuses with each leg's recorded timestamps.
- Feedback scheduler and admin calendar use final actual completion plus four elapsed hours. No messages are replayed or already-sent invitations rescheduled.
- Refresh operator scores from configured 60/40 canonical evidence; exclude platform NPS and overlapping legacy evidence. Serialize submissions and refresh before calculation.
- Verify existing captain average /5, response count and 30-day trend; unrated captains retain no score.
- Accrue pending settlements once during authorized completion, with allocation locking, existing financial amounts/liabilities and actionable missing-ledger rollback. No approval/payment.
- Preserve each boat's recorded completion timestamps in immutable audit evidence and settlement due time.

## Fresh verification

All 401 repository blobs were restored and verified byte-for-byte against GitHub commit `c78db87a6815cefa1d200b1ea46553c83531362a`, including image assets. Dependencies were restored with `npm ci` from the unchanged lockfile.

- `npm test`: 306 Node tests passed; one optional database-URL fixture test skipped; 162 Vitest tests passed across 23 files.
- `npm run build`: passed.
- `npx tsc --noEmit`: passed after the build.
- Ten SQL behavior fixtures passed on a disposable Supabase PostgreSQL 17.11 database, including the original broad feedback regression fixture. Earlier independent PGlite copies also passed all ten fixtures.
- Actual authenticated-role calls passed for customer submission, admin attribution review, captain closure and admin settlement retry. Foreign-user captain closure, non-owner feedback, site-admin quality access and foreign manifest access were rejected/empty as expected.
- Anonymous execute permissions remain denied for captain closure, both feedback overloads and the admin quality dashboard. Existing RPC grants were preserved.
- Supabase security-advisor output matched the seven production lint groups; no additional lint group was introduced. Existing auth-users-backed admin view and security-definer-view warnings remain a separate assessment.

## Real concurrent PostgreSQL evidence

The temporary branch is `completion-recovery-concurrency-2026-10-05`, project `ckxsnbybrgmkrpqzupia`, branch ID `50fe487b-b162-4fde-a46c-c524052984fe`. No production customer rows were copied. Current schema definitions, actual constraints/triggers, generated columns, identity sequences, view security options, RLS policies and relevant grants were reproduced.

The original branch replay failed before any migration because production migration history begins with public views dependent on an unrecorded base schema. The test database was initialized from a schema-only catalog export. This temporary branch must never be merged into production.

All successful races used the dashboard SQL editor for session A and the connector for session B. `pg_blocking_pids` proved actual blocking by a distinct backend; simply starting parallel MCP calls did not prove overlap.

| Case | Winner PID | Waiter PID | Recorded blocking | Result |
|---|---:|---:|---|---|
| Calculate-before-lock negative control | 7250 | 7253 | true | Two responses/12 canonical rows, but persisted score 50.40 versus combined 51.00 |
| Lock-before-calculation candidate | 7294 | 7296 | true | Score 51.00, two responses/12 canonical rows |
| Admin attribution review plus new submission | 7347 | 7349 | true | External attribution excludes the first contribution; score 50.40, two responses/12 canonical rows |
| Genuine final return closure plus concurrent retry | 7981 | 7985 | true | Identical end timestamp; both departures completed; two pending settlements/two balanced accruals |

The completion timestamp was `2026-10-05T20:13:27.755660Z` on both retry results. The two settlements each retain 2000-cent journey value, 200-cent commission and 1800-cent net payable. No unbalanced accruals or extra booking rows occurred. A subsequent protected admin settlement retry kept counts at two. Feedback due time was exactly `2026-10-06T00:13:27.755660Z`, four elapsed hours later.

The same concurrency negative control reproduced the review finding and the final candidate passed it. Manual two-session reproduction scripts are in `supabase/tests/concurrency/`.

## Historical and live-travel limits

5 October production reads: 1 October outbound is completed with a null actual departure timestamp and the previously disclosed diagnostic-generated completion; its paired return remains cancelled. These records do not prove genuine completed travel. The 2 October outbound remains `closed_unrecorded` with zero recorded captain operations.

No historical settlements, travel, messages, stored scores or cancelled returns were repaired. Two historical extended feedback responses each have overlapping legacy evidence; the canonical calculator excludes overlap without deleting audit rows.

No /captain runtime error cluster was returned for 1–5 October. The wider captain access-log aggregate timed out, so dashboard usage/attempts cannot be established from it. No recorded travel must not be represented as proof that captains did not try.

## Rulings carried forward

- Keep physical leg arrival separate from final paired completion; feedback uses final completion first. Cost if wrong: invitations could precede completed travel.
- Preserve legacy feedback as version one; exclude overlapping legacy evidence in calculation rather than deleting audit rows. Cost if wrong: historical reporting could omit or double-count contributions.
- Retain the existing protected captain average /5, count and trend instead of inventing a new ranking. Cost if wrong: the report may not satisfy a later ranking requirement.
- Preserve active assignment-owner checks before financial side effects and keep grants restricted. Cost if wrong: unauthorized completion or settlement exposure.
- Lock the operator before submission/refresh calculation; use wall-clock refresh for live submissions while preserving explicit historical as-of callers. Cost if wrong: overlapping updates could persist stale scores.
- Correct pre-existing test mock/type failures without changing product behavior or weakening assertions. Cost if wrong: test doubles could diverge from real contracts.
- Keep the original broad feedback regression fixture, updating its completed synthetic setup to the four-hour contract. Cost if wrong: an old regression case could lose coverage.
- Use each boat's recorded end for audit/settlement timing. Cost if wrong: audit evidence and due time would disagree with travel evidence.
- Apply no historical travel, settlement, message or stored-score repair automatically. Cost if wrong: historical defects remain until separately reviewed.
- Restore pruned workspace files from verified GitHub blobs and preserve real remote ancestry; never push synthetic local history. Cost if wrong: code or ancestry could be corrupted.
- Build the temporary test database from current schema-only definitions after historical replay failed; do not merge it. Cost if wrong: unverified schema parity could weaken test evidence.
- Separate completion and feedback into different requests because a single SQL protocol request shares request-start timing even across transaction commands. Cost if wrong: the fixture could misrepresent real request timing.
- Prove overlap with independent browser/connector sessions and recorded backend blocking. Cost if wrong: a serial run could be mistaken for concurrency evidence.

No unresolved minor code-review finding remains. Existing production migration-baseline drift and security advisories are separate follow-up work.

## Release and cleanup

No recovery migration is present in production as of the final read; GitHub main remains `c79a66a1b5da11ca55b4a82ccc1bce4b2fc9ccd7`. Release still requires integration of the reviewed recovery branch, applying only the four reviewed forward migrations, and production deployment.

The temporary test branch is still retained. Automatic approval review rejected deletion because it is irreversible and testing approval did not explicitly authorize disposal. Do not retry deletion indirectly. Dashboard price is $0.01344/hour plus applicable taxes until the branch is removed.

After release, verify genuine hourly phases/runtime logs, an existing suitable journey's mobile captain start/end, pending settlements, automatic invitation on the first scheduler run after +4h, inbox receipt and submitted score propagation. These live checks remain unproven by automated tests.
