# Captain Today and General release evidence

Verified locally on 2026-09-02 EDT / 2026-09-03 UTC from `feature/customer-location-presentation`.

## Release status

Local source, automated tests, production build, HTTP route smoke checks, and the approved production-schema rollback rehearsal pass. The rehearsal applied the captain migration and executed its behavioral fixture only inside an explicit outer transaction that was rolled back. No database change was committed and no preview deployment, live deployment, merge, or push was performed. Rendered authenticated browser verification and independent acceptance remain open gates.

## Source identity

- Whole-branch review starting point: `2057a92a6013e2bbfd0bf86c5e218b10d215b4dd`
- Verified implementation source commit: `db569b2f52f1ff0331e79c3cb819aacb053a799b` (`Allow feedback after allocation completion`)
- Build-fix commit: `d35943bd77a3140a1fcc10ca8829908a98ff9d24` (`Fix nullable return duration build`)
- Ultimate race/invariant fix commit: `9fcfe7ee066722b00174540bf8f5a83acbc9b042` (`Fix captain refresh and schedule races`)
- Final paired-duty invariant fix commit: `8111218c9b0d191bfa2d4c9e71d9f712f3b461b8` (`Harden paired duty lifecycle invariants`)
- Final overnight, reassignment, and resource-serialization fix commit: `836b20579902a85e4ea15004672d2d38bb79cde3` (`Close captain overnight and allocation races`)
- Runtime finalization, bounded recovery, migration preflight, and terminal-refresh fix commit: `41f893a4801e35f8702271ad1c9bfcc33e670006` (`Bound captain recovery and close finalization gap`)
- Final live-schema compatibility and post-completion feedback fix commit: `db569b2f52f1ff0331e79c3cb819aacb053a799b` (`Allow feedback after allocation completion`)
- Whole-branch blocker commits: `d5657b5` (route-mapping workflow), `78a2cf4` (recurring pair synchronization), `9e8f391` (allocation completion and incident barrier), `bb1c94c` (actor audit), `189deba` (captain private-thread initiation), `1a9ae49` (immutable evidence and idempotent first-message audit), and `7c3b86e` (atomic outbound rescheduling, leg states, and closed-window replay).
- Migration count: 48 SQL files
- Ordered `sha256sum supabase/migrations/*.sql | sha256sum` digest: `4b49cb39496a537ebf106eff2444c99e12fabd95c339e01b3e845ac11738a158`
- Captain migration SHA-256: `7931dca68c98f1a1ddf8db1fd567e0511ac22e3bc5412a179616020044e83b83`
- Captain SQL fixture SHA-256: `53dcaa3f1f84c5826d6cab80c7cdbd5d08d7865e656951f574506a7f55214997`
- Communications lifecycle fixture SHA-256: `a613058c03fde3a5de7a832ad282b2c18d1d79253f04240fb3c8113c7a708334`
- Communications security fixture SHA-256: `f76ffc3024dc9d597f30afa152c38fe8087d75a7419a4b27bc342a055d2c93bc`

## Static checks, tests, and build

| Command | Executed result |
| --- | --- |
| `git diff --check` | Pass; no whitespace errors before or after final verification. |
| `npm test` | Pass on final implementation source: 198/198 Node tests and 136/136 Vitest tests across 16 files; 334/334 total. |
| `node --test tests/captain-today-contract.test.mjs` | Pass: 44/44 captain schema, live-schema compatibility, fixture self-seeding, post-completion feedback submission, schedule serialization/first-enable protection, full paired resource-window eligibility and write serialization, legacy-data preflight, mapping/materialization, bounded overnight projection/action authorization, cross-deadline exact retry, legacy-start protection, reassignment-safe all-allocation finalization row shape, messaging, manifest, canonical evidence, compatibility, and immutability source contracts. |
| `npx vitest run components/admin-service-editor.test.tsx components/captain-dashboard.test.tsx components/captain-today.test.tsx components/journey-conversation.test.tsx components/captain-broadcast-composer.test.tsx lib/captain-today.test.ts` | Pass: 81/81 Site Admin editor and captain Today/General, manifest, per-leg state, lifecycle, cross-device monotonic reconciliation, bounded overnight carryover, terminal-row disappearance, communications, retry, refresh, and presentation-rule tests. |
| `node --test tests/booking-seat-selector.test.mjs tests/customer-booking-view.test.mjs tests/feedback-email-content.test.mjs tests/journey-broadcasts.test.mjs tests/journey-communications-release.test.mjs tests/journey-communications-sql-structure.test.mjs tests/journey-email-content.test.mjs tests/journey-messaging-api.test.mjs tests/journey-messaging-migration-chain.test.mjs tests/journey-notification-contract.test.mjs tests/service-specific-offers.test.mjs` | Pass: 77/77 booking, allocation, private/broadcast communications, T-24, feedback, and settlement-boundary source contracts. |
| `npm run build` | Pass: compiled and type-checked, generated 25 routes, and collected build traces. |

The earlier production build failed at `components/admin-service-editor.tsx` because `duration` was possibly `null`. `git blame` traced the expression to Task 2 commit `b18f7bd174945bf76ffb0ebb5dc22954d5403868`, so it was a branch defect rather than a pre-existing baseline failure. The failing production build served as the red type-safety test. Commit `d35943b` added the explicit non-null guard. The final 15-test editor suite and production build pass.

The final review fixes followed focused RED/GREEN cycles. New contracts first failed for the missing route-mapping product boundary, one-row recurrence materialization, allocation-wide completion barrier, incident sequencing, actor attribution, protected thread initiation, immutable pair/evidence state, first-message request identity, prior-schedule outbound capture, completed-request replay ordering, and visible per-leg lifecycle state. Those contracts pass at the verified implementation commit. This records local source/unit evidence only; it does not represent execution of the SQL fixture by PostgreSQL.

The ultimate race/invariant review added three focused RED/GREEN boundaries. Today refresh reconciliation now requires the submitted RPC timestamp, allocation, duty/departure identities, completion payload, and a valid strict-state-machine state, while accepting any legal later state; tests cover Start Leg 1 observed after Leg 1 has ended, End Leg 1 observed after Leg 2 has started, rejection of missing/different evidence, and retry recovery. A commercial future scheduled service departure now takes the service row, service-design advisory, and departure advisory locks in that order in a `BEFORE INSERT` trigger, rejects stale schedule/date/recurrence/timezone rows with SQLSTATE `40001` and stable retry text, and reaches the `AFTER INSERT` materializer only after validation. The rollback SQL fixture simulates a stale pre-edit generator insert followed by a valid post-edit retry. Normal completion now submits an empty summary from the UI, stores canonical SQL `NULL`, rejects nonblank Normal summaries, and treats blank/`NULL` Normal retry forms identically; Incident continues to require a nonblank summary. The source/unit contracts pass, and the rollback rehearsal executed the fixture successfully against the production schema without committing its transaction.

The final paired-duty review added five further RED/GREEN boundaries. A single private resource-window helper now defines the outbound-to-return-arrival interval used by vehicle offers, public/partner inventory, default-captain selection, and deferred allocation validation; both outbound and return routes must support the vehicle type, and captain, vehicle-allocation, and vehicle-unavailability overlaps through Leg 2 are rejected. First return enablement locks and preflights every future commercial service departure before mutation, rejects bookings, allocations, active quotes, pre-existing pairs, and operational evidence with stable domain text, while pairing all pristine qualified rows and leaving unqualified unprotected rows untouched. Shared final completion locks allocations in stable order and invokes legacy voyage/settlement/feedback integration once for every confirmed allocation, with immutable evidence written transactionally before the allocation-wide barrier. Paired message close time follows return actual/final-operation completion and cannot expire while Leg 2 remains incomplete; one-way timing remains unchanged. Manifest fallback now selects one deterministic passenger row instead of independently aggregating first and last names. The passing rollback fixture exercised active-quote and pair rejection with no partial state, safe first enablement, Leg 2 resource conflicts, all-allocation integration/retry counts, delayed/post-completion messaging, one-way compatibility, real-row passenger names, and an authenticated feedback submission after paired allocation completion against the production schema inside the rolled-back transaction.

The final narrow review added further RED/GREEN boundaries. All-allocation legacy integration now uses the current unique active eligible assignment only as the authorized legacy integration identity while retaining the completed operation's immutable actor, completion state, notes, and incident payload; an inactive original assignment can no longer remove that allocation from the batch, ambiguity fails the transaction closed, and the finalization loop explicitly projects every field it later reads, including `assignment_count`. Paired duties that began before local midnight remain in Today and may continue Start/End/Incident operations only through the later scheduled-arrival timestamp plus a 24-hour recovery period; stale unfinished duties disappear and actions receive stable Site Admin escalation text, while an immutable actor/payload exact terminal End replay remains idempotently available beyond the ceiling. A successful final Leg 2 End may legitimately remove a prior-date duty from the protected projection: the UI accepts only a valid scoped absence with no matching duty/allocation or stale manifest identity, clears the pending refresh, draft, and selection, and displays any remaining duty, including a sibling allocation sharing the same physical leg IDs; nonterminal absence remains rejected. The legacy start RPC can no longer create unaudited paired departure/voyage evidence: the audited start RPC grants a private transaction-local operation flag only around the legacy call.

Under the default `READ COMMITTED` source design, confirmed-allocation validation takes a global allocator advisory gate followed by stable lexically ordered captain/vehicle resource locks, and deferred dependency triggers revalidate confirmed allocations when vehicle unavailability or route/vehicle eligibility changes. This design is intended to serialize conflicting resource writes and preserve a stable lock order; a dedicated two-session commit-order race was not part of this single-transaction rehearsal, so runtime elimination of write skew or deadlock is not claimed from this result. The migration also invokes the new invariant for every existing confirmed allocation in deterministic ID order and aborts on a legacy conflict instead of silently grandfathering it. The passing rollback fixture exercised assignment replacement, complete finalization row shape, exact retry counts, bounded overnight continuation/terminal disappearance, cross-deadline exact replay, legacy-start denial, dependency-change rejection, and legacy-conflict preflight rejection.

The full test output includes `Customer email dispatch failed claim unavailable` on stderr. This is intentional evidence for the mocked retryable email-claim failure: the test asserts HTTP 503 and `{ error: 'Customer email dispatch failed' }`, and passes. `git blame` shows the log line and test boundary are inherited from merge-base/main commit `5f59e9a5a14be94011985eb38a4f7beb1fd020ad`; the message is not a Captain feature regression.

Non-failing build/test warnings were the npm `http-proxy` deprecation warning, Next.js multiple-lockfile root inference, and Node module-type reparsing warnings.

## Production-schema rollback rehearsal

Status: **passed at `db569b2f52f1ff0331e79c3cb819aacb053a799b`**.

With explicit approval and no live users, the captain migration and `captain_duties_and_return_legs_contract.sql` were executed against the production schema inside one outer rollback transaction. The migration compiled and completed against the live schema, and the complete captain behavioral fixture passed, including authenticated customer feedback submission after paired allocation completion. The transaction was then rolled back; this was a compatibility rehearsal, not a deployment. Earlier rollback-only attempts exposed live-schema drift and fixture assumptions and were fixed before this final pass; none of those attempts committed data or schema changes.

Post-rollback verification recorded:

| Check | Result |
| --- | --- |
| `pace_v2.journey_pairs` | Absent, matching the pre-rehearsal schema. |
| Captain migration history row | Absent; migration remains unrecorded. |
| `pace_v2.departures.actual_departure_ts` | Absent, matching the pre-rehearsal schema. |
| Active sessions | 0. |
| Waiting locks | 0. |
| Other exclusive locks | 0. |

This pass provides executable production-schema compatibility and single-transaction behavioral evidence for the captain migration. It does not claim a committed production migration, a fresh-database replay of all 48 migrations, a dedicated two-session commit-order race, execution of the separate communications/T-24 fixture suite, or rendered authenticated browser coverage.

## Browser and responsive verification

Status: **public HTTP smoke passed; rendered/authenticated scenarios blocked**.

The final successful production build was started locally on loopback. These routes returned HTTP 200 with non-empty HTML:

| Route | Bytes |
| --- | ---: |
| `/` | 8,966 |
| `/book` | 9,427 |
| `/customer` | 7,921 |
| `/captain` | 6,672 |
| `/captain?tab=general` | 6,716 |
| `/operator` | 7,871 |
| `/admin` | 6,882 |
| `/admin/journeys` | 7,566 |
| `/admin/network` | 7,562 |
| `/legal/terms` | 6,662 |

No Chromium, Chrome, Firefox, Playwright, Puppeteer, or browser automation tool is installed, and no protected role sessions or database fixtures are available. Therefore screenshots and rendered measurements at 390×844 and 1440×900 could not be captured. Source inspection confirms a mobile breakpoint at 700px and explicit 48px minimum heights for workspace tabs, Today tabs, duty/party controls, leg actions, and communication actions. The 81 focused UI/rule tests verify the Site Admin mapping/editor workflow and disabled-return outbound-time payload, Today defaulting, URL-backed General separation, active/next selection, grouped manifest disclosure, Scheduled/Under way/Completed/Incident per-leg badges, start/end confirmations, Normal/Incident canonicalization, cross-device legal-later-state reconciliation and retry, bounded overnight visibility, terminal-row disappearance with shared-departure siblings, private-thread initiation/retries, party/all messaging, stale-context guards, and refresh reconciliation. Actual no-horizontal-overflow geometry and browser-measured touch targets remain blocked rather than inferred.

## Regression and security boundary assessment

- One-way compatibility: local captain contracts pass; executable preview scenario blocked.
- Booking/checkout and allocation: focused source contracts pass; executable preview lifecycle blocked.
- T-24 communications and protected messaging: focused/full suites pass; preview delivery/role checks blocked.
- Final-leg settlement and post-duty feedback: structural and unit contracts pass; preview trigger observation blocked.
- End Leg 1 triggers neither settlement nor feedback: assertion exists in the captain rollback fixture and its source contract passes; preview execution blocked.
- Role security: grants, invoker boundaries, identity matrix, and denial assertions pass source contracts; end-to-end database execution blocked.

## Independent review

Tasks 1–7 record completed independent review cycles in the SDD ledger. A whole-branch review then identified the route-mapping, recurrence, allocation barrier, incident, actor, private-thread, pair-immutability, atomic outbound-time, leg-state presentation, and replay-ordering blockers addressed by the commits above. This execution context explicitly prohibited agent delegation, so independent acceptance of the resulting fixes remains an external gate. The final implementation was self-reviewed and covered by focused suites, the full suite, production build, and loopback HTTP smoke; no preview database or rendered browser execution is claimed.

## Activation gate

Release is stopped. Required next gates are: provide a provably isolated preview Supabase target and database tooling, execute the recorded SQL/role/regression scenarios, provide browser automation plus protected role fixtures for both viewports, and complete independent review. Only then may explicit approval for live migration and production activation be considered.

Live database migration: NOT APPLIED — awaiting explicit user approval.
Production deployment: NOT ACTIVATED — awaiting explicit user approval.
