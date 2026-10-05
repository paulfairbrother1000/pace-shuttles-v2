# Completion/feedback recovery — verification and release gate

Production unchanged. Forward-only migrations are prepared on the recovery branch.

## Implemented

- Retain completed outbound passenger parties on paired returns; genuine multi-boat final completion updates both leg statuses with each leg's recorded timestamps.
- Feedback scheduler and admin calendar use final actual completion plus four elapsed hours. No messages are replayed or already-sent invitations rescheduled.
- Refresh operator scores from configured 60/40 canonical evidence; exclude platform NPS and overlapping legacy evidence. Serialize submissions and refresh before calculation.
- Verify existing captain average /5, response count and 30-day trend; unrated captains retain no score.
- Accrue pending settlements once during authorized completion, with allocation row locking, existing financial amounts/liabilities and actionable missing-ledger rollback. No approval/payment.
- Preserve each boat's recorded completion timestamps in immutable audit evidence and settlement due time.

## Database evidence

Ten SQL behavior fixtures passed on independent disposable PGlite database copies using production schema definitions, actual functions/constraints/triggers and synthetic data only. This includes the original broad feedback regression fixture, now seeded with two completed journeys in distinct countries.

Observed RED failures before fixes: paired completion did not complete both legs; completed parties were treated as empty; feedback used next-day timing; submission did not refresh the 60/40 score; genuine completion did not accrue settlements; separated boat ends produced inconsistent settlement/audit timestamps. All corresponding cases subsequently passed.

Local owner execution tests verify RPC identity checks, not production-role ACL/RLS parity. Read-only production ACL checks show existing restricted public RPC grants; replacements preserve those grants. No customer rows were copied into test databases.

Full verification after the review fixes: 306 Node tests and 162 Vitest tests passed; production build passed; standalone TypeScript check passed when run after build (not concurrently with generated type-file regeneration).

## Read-only historical findings

5 October: two existing extended feedback responses each have overlapping legacy evidence. The calculator excludes overlap without deleting audit rows. No historical settlements, travel, messages or stored scores were repaired.

## Release gate

PGlite has one connection. Two genuinely concurrent feedback submissions/attribution reviews and completion/accrual retries must be exercised on a disposable multi-session PostgreSQL/Supabase database before merging/applying these financial migrations. Local locking inspection is not experimental concurrency proof.

After release, verify genuine hourly scheduler phases, runtime logs, mobile captain start/end, pending settlement, first hourly invitation after +4h, inbox delivery and submitted feedback score propagation. Do not infer these from automated tests.

Existing production security advisories include an authenticated auth.users-backed admin-access view. This is unrelated to the branch and requires separate assessment: https://supabase.com/docs/guides/database/database-linter?lint=0002_auth_users_exposed
