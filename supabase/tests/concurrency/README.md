# Completion and feedback concurrency verification

Use two independent connections to a disposable PostgreSQL/Supabase database with the current production schema and the four recovery migrations. Never execute these fixtures on production. The committed synthetic fixture is not application data; do not send its messages.

For feedback, load `../fixtures/completion_feedback.sql`, call `pg_temp.complete_fixture()`, and commit. Start session A, then session B while A is waiting. A must return different winner/waiter backend IDs and `blocked=true`; the score must be 51.00, with exactly two feedback responses and twelve canonical evidence rows. Application RPC calls run as `authenticated` with synthetic user 101. The row lock and barrier are orchestration performed by the test administrator.

For completion, start with a new disposable copy of the fixture. Captain 102 records both legs for allocation 50. Captain 103 records leg one and starts leg two for allocation 51. Commit this setup without ending that final leg. Start completion session A and then B. Both return the same immutable end timestamp. Both departures complete, exactly two pending settlements carry 2000/200/1800-cent snapshots, exactly two accrual transactions exist, and each has zero debit/credit imbalance. Retry `v2_admin_create_settlement(allocation51,now())` as synthetic admin 100: counts remain two.

The denial fixture runs with the authenticated database role and synthetic foreign user 104. It rejects captain closure, non-owner feedback and site-admin reporting, and exposes no captain manifest.

On 5 October 2026 a calculate-before-lock negative control produced 50.40 despite two committed responses; the lock-before-calculation candidate produced 51.00 under the same observed blocking. An admin attribution review of booking 80 to external overlapping a new booking-81 submission also produced the correct 50.40 score.

Supabase MCP requests alone did not establish overlap. The successful experiment used the dashboard SQL editor for A and the connector for B, with `pg_blocking_pids` proving overlap. See the verification report for exact backend IDs and results. These scripts are a manual two-session harness, not a claim that the optional Node database-fixture test ran.
