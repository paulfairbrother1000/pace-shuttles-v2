# Pace Shuttles V2 — Scheduled Service Access Runbook

The protected endpoint `GET /api/operations/run-scheduled` is the only application path for recurring journey scheduling and customer-email dispatch. It runs hourly from `vercel.json` (`0 * * * *`). Browser clients never receive the Supabase service-role key.

This is release-candidate guidance. The Tasks 1-7 migrations and Task 8 SQL fixtures still require execution in an approved non-production Supabase context before any production activation claim.

## Server-only configuration

Configure these values in the deployment environment, never in browser-visible variables or committed files:

| Variable | Purpose |
| --- | --- |
| `CRON_SECRET` | Authenticates the Vercel cron request as `Authorization: Bearer <value>` |
| `SUPABASE_SERVICE_ROLE_KEY` | Creates the server-only Supabase client used by scheduler/claim/mark RPCs |
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase project URL; public by design, but paired with the server-only key only inside the route |
| `RESEND_API_KEY` | Sends claimed customer emails |
| `RESEND_FROM_EMAIL` | Verified sender used by the dispatcher |

Rotate `CRON_SECRET`, `SUPABASE_SERVICE_ROLE_KEY`, or `RESEND_API_KEY` immediately if exposed. Never copy them into a browser request, client component, log, SQL fixture, or support message.

## Request boundary

The endpoint accepts only the exact bearer secret. Missing/wrong authorization returns `401`; missing Supabase server configuration returns `500`; scheduler database failures return `500`; dispatcher setup/claim failure returns `503`.

A manual preview invocation, when explicitly approved, uses the preview URL and a secret from the preview environment:

```bash
curl --fail-with-body --header "Authorization: Bearer $PREVIEW_CRON_SECRET" \
  "https://<approved-preview-host>/api/operations/run-scheduled"
```

Do not run this command against production as a dry run: the endpoint schedules and can deliver real email.

## Execution order

One successful request performs the following sequence:

1. Run the established `v2_system_run_scheduled_operations` T-72/T-24 operational work.
2. Invoke `v2_system_schedule_t24_journey_notifications(p_as_of)`.
3. Invoke `v2_system_schedule_feedback_requests(p_as_of,p_limit)`.
4. Claim at most 25 due queue rows through `v2_system_claim_due_customer_emails_with_metadata(p_limit)`.
5. Send each claimed email with a notification-derived idempotency key.
6. Mark the canonical notification sent/failed; for broadcasts, atomically update the linked broadcast delivery through the journey-specific mark RPC.

Queue rows and recipients are derived server-side. The endpoint does not accept caller-supplied booking, recipient, captain, vehicle, route, timezone, or message content.

## Service-role RPC inventory

| RPC | Purpose | Browser access |
| --- | --- | --- |
| `v2_system_schedule_t24_journey_notifications(timestamptz)` | Queue one complete tomorrow reminder per eligible booking and raise/recover detail exceptions | Revoked |
| `v2_system_schedule_feedback_requests(timestamptz,integer)` | Queue one request at next-local-day 10:00 per eligible completed booking | Revoked |
| `v2_system_claim_due_customer_emails_with_metadata(integer)` | Lock a bounded valid-recipient batch using `SKIP LOCKED` and return delivery metadata | Revoked |
| `v2_system_mark_journey_broadcast_email_sent(uuid,uuid,text)` | Atomically mark matching notification/delivery sent | Revoked |
| `v2_system_mark_journey_broadcast_email_failed(uuid,uuid,text)` | Preserve in-app message and record matching notification/delivery failure | Revoked |

Each function is `SECURITY DEFINER` with a fixed `search_path`, default PUBLIC/anon/authenticated execution revoked, and only the minimum service-role grant. Authenticated customer/captain/Site Admin RPCs separately validate `auth.uid()`, ownership, assignment, or Site Admin status inside the function.

## Non-production release verification

Apply all migrations in timestamp order to an approved preview/test database, then run every SQL fixture with stop-on-first-error semantics. A PostgreSQL client example is:

```bash
for sql_file in supabase/tests/*.sql; do
  psql "$NON_PRODUCTION_DATABASE_URL" --set ON_ERROR_STOP=1 --file "$sql_file" || exit 1
done
```

The journey release fixtures are transaction-wrapped and end in `rollback`:

- `supabase/tests/journey_communications_security_contract.sql`
- `supabase/tests/journey_communications_end_to_end.sql`

Also run:

```bash
npm test
npm run build
git diff --check
supabase db advisors
supabase migration list --linked
```

Run the Supabase commands only when the CLI is deliberately linked to the approved non-production project. Inspect advisor output, function ACLs, RLS enablement/policies, and all public exposed views. A passing static Node test is not a substitute for executing the SQL against PostgreSQL.

## Preview role journey

Use distinct test identities for customer A, customer B, assigned captain, other captain, operator-only user, and Site Admin. Verify T-24 reminders, private reply isolation, two-copy broadcast fan-out, queued/claimed email state, completion +4h closure, next-local-day 10:00 feedback requests, one owner-only feedback response, and separated platform/operator/captain/pickup/destination evidence.

Inspect:

- Vercel cron/function status and logs;
- Supabase function errors and advisor results;
- `v2_admin_operational_alerts` for unresolved T-24, timezone, completion, or delivery exceptions;
- notification status/provider references; and
- broadcast delivery status/failure reason.

## Incident actions

| Signal | Immediate action |
| --- | --- |
| Repeated `401` | Verify Vercel cron secret binding; rotate if mismatch is unexplained |
| `500` scheduler error | Stop manual retries, inspect the named RPC/database error, and preserve queue evidence |
| `503` dispatcher error | Verify server-only Supabase/Resend configuration and claim RPC; queued work remains retryable |
| Queue backlog | Check schedule cadence, `scheduled_for`, recipient validity, locks, and provider failures before increasing limits |
| Duplicate concern | Do not delete evidence; inspect booking/template unique keys, broadcast request ID, notification ID, and provider idempotency key |
| Invalid recipient | Correct the authoritative account data and review the operational alert; do not bypass the validator |

## Activation and rollback gate

Production activation requires explicit approval after the PR, migration list, automated totals, executed SQL results, advisor output, preview URL, role-by-role browser evidence, logs, and open caveats are presented.

If preview verification fails, do not merge or apply production migrations. Pause the preview cron, retain failed/queued rows and operational alerts for diagnosis, deploy the last known-good application revision, and fix forward in a new reviewed migration. Because these migrations are additive and communications rows are audited, do not manually drop tables or delete production queue/message/evidence rows as a rollback shortcut.

After approved production migration and deployment, verify the access gates and scheduler read-only/dry-run capability if the deployed interface supports one. The current endpoint is not read-only, so any controlled production non-delivery fixture requires separate explicit approval, transactional cleanup, and a zero-residual-row check.
