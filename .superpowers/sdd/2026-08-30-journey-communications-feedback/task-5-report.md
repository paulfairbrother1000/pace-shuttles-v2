# Task 5 report — customer/captain conversation interfaces

## RED

- Added `components/journey-conversation.test.tsx` before the component existed.
- `npx vitest run components/journey-conversation.test.tsx` failed because `./journey-conversation` was absent.
- `node --test tests/journey-messaging-ui.test.mjs` failed because the component source was absent.

## GREEN and verification

- Focused component tests: 3/3 passed.
- Focused messaging/broadcast contract tests: 11/11 passed.
- Full `npm test`: 84 Node tests and 27 Vitest tests passed.
- `npm run build`: compiled, type-checked, generated all 24 static pages, and completed trace collection. Next warned only about the worktree/root lockfile inference.
- `next-env.d.ts` was restored with `apply_patch` after build generation.

## Browser evidence

- Started the local Next server at `127.0.0.1:3000`; it reached Ready state.
- `agent-browser` was unavailable on PATH. `npx --yes agent-browser` was available but its daemon exited during startup without output, including with `--debug`, so no browser snapshot could be captured.
- The server was stopped. Authenticated customer/captain role pages were not manually reachable; their open, scheduled, closed, send, category, and retry states are covered by component and source-contract tests.

## Files

- `components/journey-conversation.tsx` and its component test.
- `components/captain-dashboard.tsx` for party threads, unread labels, private replies, and retry-safe all-party broadcasts.
- `components/pages.tsx`, `lib/data.ts`, and customer styles for the protected customer messaging adapter and view loaders.
- `tests/journey-messaging-ui.test.mjs` for action/category/unread/no-contact-detail contracts.

## Self-review

- The thread accepts only explicit props, uses accessible form controls, avoids raw contact-detail fields, and derives view state during render.
- Broadcast retries retain the existing allocation-reset lifecycle and clear only after a changed draft/category or successful send.
- Database views/RPCs remain the authorization boundary; the UI does not infer access rights.

## Concerns

- Browser verification remains unavailable because the local `agent-browser` daemon exits during startup without output; it was not retried beyond the documented attempts.

## Follow-up integration

- Added a RED source integration test that scoped `CustomerSearch` and failed because the selected booking did not mount `CustomerDayOfTravel`.
- Wired `<CustomerDayOfTravel booking={selected}/>` into the live Help & Support panel, immediately after the selected booking summary and before ordinary support history/form controls.
- The adapter now uses Task 3 protected conversation/message loaders and customer RPC wrappers, renders loading/error/scheduled/closed fallback copy, and retains ordinary Pace Shuttles support alongside the private thread.
- GREEN: focused messaging tests pass (3 source contracts and 3 component tests); full `npm test` passes (85 Node tests and 27 Vitest tests); build compiled, type-checked, generated 24 static pages, and collected traces.
- Restored generated `next-env.d.ts` and `tsconfig.tsbuildinfo` after verification; neither is part of the follow-up commit.

## Hardening round 1

- RED: the selected-booking source integration contract initially failed because the live customer panel had no mounted Day of Travel adapter.
- Added CLI-generated migration `20260831011259_journey_message_read_state.sql` with a server-authorized owned-booking window projection (including first-contact windows), private audience read markers, unread counts in protected views, and a mark-read RPC.
- The customer adapter loads the projection, uses server state for scheduled/open/closed first contact, rejects its send promise after surfacing an error, and marks the opened private conversation read. Captain threads now mark read, have stable party labels, reset drafts by thread identity, preserve failures for retry, aggregate unread across every assigned conversation, and disable all-party messaging outside an open window.
- GREEN: focused component suite 5/5; messaging contract suite 4/4; `npm test` passed 86 Node tests and 29 Vitest tests; production build compiled, type-checked, generated all 24 pages, and collected traces before generated-file restoration.
- Browser verification was not retried because the documented daemon retry limit was already reached.

## Hardening round 2

### RED

- Added the captain first-broadcast projection contract before the dashboard used it. `node --test tests/journey-messaging-ui.test.mjs` failed at `loadCaptainJourneyMessageWindows`, proving an allocation with no existing private conversation could not yet enable the UI.

### GREEN and verification

- Added narrowly authorized security-definer window helpers for owned paid customer bookings and assigned captain allocations, with authenticated-only execute grants. The security-invoker projections use those helpers; raw allocation and read-state tables remain ungranted.
- Replaced direct unread-table access in views with `authorized_journey_conversation_unread_count`, which validates audience access, uses a fixed search path, and counts only non-self messages after the caller's private read marker.
- Customer and captain await mark-read then reload protected conversation rows. Conversation mounts are keyed by booking/conversation identity, preventing a deferred A request from clearing B's draft. Broadcast text/category/request identity reset on allocation changes while same-allocation failed retries retain their request id.
- The captain panel now loads the assigned allocation window projection, so Message all parties is available for an open allocation before a conversation exists and remains unavailable for scheduled/closed allocations.
- Added rendered `CaptainDashboard` integration coverage using protected-view-shaped loader rows: it verifies an open allocation can message all parties without a conversation, while a closed allocation keeps the action unavailable and renders unread state.
- Focused contract tests: 6/6 passed. Focused dashboard/conversation tests: 7/7 passed. Full `npm test`: 88 Node tests and 31 Vitest tests passed. `npm run build` compiled, type-checked, generated 24 static pages, and collected traces.
- Restored generated `next-env.d.ts` and `tsconfig.tsbuildinfo`; neither is committed.

### Browser / concerns

- Browser verification was not retried: the earlier daemon failure had already reached the permitted retry cap. No server was started in this round.
- Customer Day of Travel remains embedded in the legacy `pages.tsx` panel, so its live selected-booking mount and protected loader wiring are source-contract tested; follow-up cleanup should extract it into an independently injectable module for deferred-promise parent rendering tests.

### Commit and self-review

- Local commit: `c85ebb8 fix: harden journey messaging projections`.
- Reviewed the staged diff for privacy (no raw email/phone fields), authorization (all window and unread reads are server-scoped), request identity (same-allocation retry retained), and generated files (restored, not committed).

## Hardening round 3

### RED / GREEN

- RED: the existing broadcast lifecycle contract still expected the old effect reset. It failed after the composer boundary removed that effect; the replacement contract and rendered composer test verify allocation-key remount behavior instead.
- Replaced the customer security-invoker booking scan with the no-argument, authenticated-only `public.v2_customer_my_journey_message_windows()` security-definer RPC. It enumerates only `auth.uid()` owned paid-active bookings internally, derives windows server-side, and has no caller-controlled booking probe.
- Extracted `CustomerDayOfTravel` with typed injectable loaders/actions. Rendered tests cover open first contact, scheduled/closed copy, loader error fallback, and failed-send draft retention.
- Extracted the keyed `CaptainBroadcastComposer`; it has allocation-local initial state, catches UI event failures, retains failed drafts/request ids, and immediately starts B blank/default after A→B remount. `JourneyConversation` now relies on keyed parent identity instead of an effect reset.
- Captain row loading uses an incrementing request guard to ignore stale async completions.
- GREEN: focused Node contracts passed 15/15; focused rendered tests passed 11/11. Full `npm test` passed 88 Node tests and 35 Vitest tests. `npm run build` compiled, type-checked, generated 24 static pages, and collected traces. Generated `next-env.d.ts` and `tsconfig.tsbuildinfo` were restored.

### Browser / concerns

- Browser verification was not retried because the previously documented daemon retry cap remains in force.
- `CustomerSearch` retains its legacy one-line body, so the extracted customer panel is mounted live but parent-selected-booking remount cleanup should be addressed alongside a future split of that legacy panel.

### Commit and self-review

- Local commit: `95cf745 refactor: isolate journey messaging panels`.
- Reviewed the committed diff: the customer window RPC accepts no booking argument, public/anon are revoked, the broadcast click handler absorbs failures, and generated files are clean.

## Hardening round 4

### Commit reference correction

- The repository history identifies hardening round 2 as `c8a3775 fix: harden journey messaging projections`, not the historical `c85ebb8` reference above.
- The repository history identifies hardening round 3 as `40993a5 refactor: isolate journey messaging panels`, not the historical `95cf745` reference above. The earlier text remains unchanged as historical execution notes.

### RED

- Migration-chain contract: 0/2 passed. The applied `20260831011259_journey_message_read_state.sql` checksum was `208612b...` instead of the `c8a3775` checksum `abb5d10...`, and no forward `journey_messaging_projection_hardening` migration existed.
- Customer rendered suite: 5/7 passed. A rejected loader left the panel permanently loading with an unhandled rejection, and a deferred older mark-read reload removed the newer post-send message. The live-mount contract also failed because the selected booking did not key `CustomerDayOfTravel`.
- Captain rendered suite: 0/7 passed. The dashboard ignored the wished-for injected loaders/actions and fell through to the unconfigured production client, proving it had no testable dependency boundary. The suite covered deferred loader/action selection races, mark-read ordering, scheduled/open states, private send failure/success, broadcast request identity, and unread aggregation.

### GREEN

- Restored `20260831011259_journey_message_read_state.sql` byte-for-byte to `c8a3775` (`sha256 abb5d105c1a205d6ff1405fcc8a60e3f2f95b5b103d0f6e8a19c34e3003dbd45`).
- Used the cached Supabase CLI with update checks and telemetry disabled to create `20260831015350_journey_messaging_projection_hardening.sql`; no database command was run. The forward migration revokes and drops the superseded view, creates/grants the no-argument owned-booking RPC, and removes authenticated access to the keyed booking helper while retaining owner-internal use.
- Customer row loads now sequence and cancel stale completions, rejected loaders/actions surface recoverable UI errors, mark-read and send operations cannot supersede one another incorrectly, and the live selected-booking mount is keyed by booking id.
- CaptainDashboard now accepts typed optional loader/action dependencies backed by the existing production functions. Loader completions and action refreshes are guarded, allocation/party changes invalidate prior work, and rejected dependencies cannot strand dashboard state.
- Replaced the obsolete source-regex assertions for async dashboard behavior with rendered tests of the actual dashboard and customer panel.

### Verification

- Focused rendered suites: 20/20 passed across customer, captain, conversation, and broadcast composer tests.
- Focused migration/UI contracts: 7/7 passed.
- Full `npm test`: 89 Node tests and 44 Vitest tests passed. Existing Node module-type and npm proxy warnings remain.
- `npm run build`: compiled, type-checked, generated all 24 static pages, and collected traces; exit code 0. The existing workspace-root warning remains.
- Restored generated `next-env.d.ts`; generated files are not part of this round.
- Per the existing daemon cap, browser verification was not retried. Per task scope, no remote database was used; the SQL database contract was updated but not executed against a database in this round.

### Self-review

- Rendered coverage now demonstrates only the stated async and messaging behaviors; it does not claim browser or live-database verification.
- The keyed customer booking probe is no longer callable by authenticated clients, and no UI references it.
- The round-4 commit is the commit containing this report; its final hash is reported in the handoff rather than embedded self-referentially here.

## Hardening round 5

### RED

- Added rendered deferred-action coverage before changing production code. After correcting one ambiguous test selector, `npx vitest run components/captain-dashboard.test.tsx --reporter=dot` failed 4 tests and passed 8.
- The successful stale private reply, journey start, journey completion, and broadcast cases each expected the relevant loader to be called twice but observed one call. This reproduced the load-bearing early return: switching party or journey invalidated the same operation generation that guarded both context-specific UI state and shared-data refresh.
- The stale failed-broadcast case passed during RED, confirming the existing dashboard did not claim success or clear the newer journey composer on an abandoned failed action.

### GREEN

- Split `CaptainDashboard` sequencing into a selection-scoped `contextOperation` generation and an independent `refreshRequest` generation. Selection changes still suppress abandoned busy state, notices, and composer effects, while every successful reply, broadcast, start, or completion awaits a globally sequenced refresh of journeys, manifest, conversations, messages, and messaging windows.
- The independent refresh token and each loader's request generation prevent an older refresh completion from overwriting newer shared rows. The explicit selected journey/conversation ids remain untouched by refreshes, so the active B selection and its draft survive an A action completing in the background.
- Updated the obsolete round-4 assertion that required no reload after an allocation switch; it now requires the reload and still verifies the later allocation remains rendered.
- Focused dashboard suite: 12/12 passed. Broader rendered messaging suites: 25/25 passed. Focused migration/UI contracts: 7/7 passed.
- Full `npm test`: 89 Node tests and 49 Vitest tests passed. Existing Node module-type and npm proxy warnings remain.
- `npm run build`: compiled and type-checked successfully, generated all 24 static pages, and collected build traces. The existing workspace-root warning remains.
- Restored generated `next-env.d.ts`; no generated file is included in this round.

### Scope / concerns

- Per the existing browser retry cap, browser verification was not retried. No remote database command was run.
- No new functional concern was found in this round; verification still carries only the pre-existing repository warnings documented above.
