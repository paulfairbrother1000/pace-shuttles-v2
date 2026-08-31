# Task 8 release verification

Verified on 2026-08-31 from branch `feature/journey-communications-feedback`.

## Result

The Task 8 implementation is locally and preview-database verified. Production activation is not approved or performed. The live Supabase database and production deployment were not changed.

Release remains stopped before activation for explicit approval and for the two external gates listed below.

## Evidence

| Gate | Evidence | Result |
| --- | --- | --- |
| Node contracts | `npm test`: 124/124 Node tests passed | Pass |
| Component tests | `npm test`: 11 files, 65/65 Vitest tests passed | Pass |
| Production build | `npm run build`: compiled, type-checked, and generated 24 routes | Pass |
| Preview migrations | All nine Task 8 migrations applied to a schema-only production-shaped Supabase preview | Pass |
| Preview SQL | 13/13 Task 8 contract, behavior, end-to-end, and security fixtures executed successfully | Pass |
| Security identities | Customer A, Customer B, assigned captain, other captain, operator-only user, Site Admin, anon, and service-role boundaries exercised | Pass |
| Runtime route smoke | `/`, `/book`, `/customer`, `/captain`, `/operator`, `/admin`, `/admin/journeys`, and `/legal/terms` compiled and returned HTTP 200 with non-empty HTML | Pass |
| Browser rendering | Local browser CLI unavailable; cloud browser blocks loopback addresses | Blocked by verification infrastructure |
| Remote branch | Push attempted, but this environment has no GitHub HTTPS credentials | Blocked by credentials |

## Preview database

- Production project: `prvzgvkuefcflvmepuhd` (read-only inspection only)
- Preview branch: `task-8-release-verification-20260831`
- Preview project: `xmkkfaaxcldbuwqsyqtk`
- Preview data: synthetic fixtures only; no production rows copied
- Schema compatibility defects discovered and fixed: canonical notification columns/state, order ownership joins, arrival synchronization, production booking statuses, captain name constraints, timing fields, quality-evidence legacy columns, timezone evaluation, private-message table naming, and owner-safe RLS helpers

The preview branch is temporary and is deleted after this report and commit are finalized.

## SQL fixtures executed

1. `journey_communications_foundation_contract.sql`
2. `journey_communications_foundation_behavior.sql`
3. `t24_journey_notifications_behavior.sql`
4. `private_journey_messaging_contract.sql`
5. `private_journey_messaging_behavior.sql`
6. `captain_journey_broadcasts_behavior.sql`
7. `journey_message_read_state_contract.sql`
8. `journey_feedback_quality_contract.sql`
9. `journey_feedback_quality_behavior.sql`
10. `admin_journey_quality_reporting_contract.sql`
11. `admin_journey_quality_reporting_behavior.sql`
12. `journey_communications_end_to_end.sql`
13. `journey_communications_security_contract.sql`

## Advisor review

Supabase security and performance advisors were run after the preview DDL.

- RLS-without-policy notices are intentional deny-all protection for internal base tables; public access is through narrowly granted views/RPCs.
- Authenticated `SECURITY DEFINER` RPC warnings are intentional API boundaries. Each RPC checks the caller and the security fixture proves cross-role denial.
- Supervised/security-definer view notices are mitigated by explicit grants, caller predicates/admin checks, inaccessible base tables, and the full identity matrix.
- Performance recommendations are non-blocking: missing covering indexes on several foreign keys, two `auth.uid()` initialization-plan optimizations, and unused-index notices on the new empty preview.

Reference: [Supabase database linter](https://supabase.com/docs/guides/database/database-linter).

## Activation checklist

- Provide GitHub credentials and push the verified commits.
- Run the rendered browser pass in CI or an environment whose browser can reach the app preview.
- Review this report and grant explicit activation approval.
- Only after approval: apply migrations to live and deploy/promote production.

