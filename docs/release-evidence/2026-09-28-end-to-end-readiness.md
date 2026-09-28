# End-to-end readiness — 28 September 2026

## Verified changes

- The scheduled processor and site-admin catch-up now cancel expired empty non-commercial paired returns with the reason `Closed after departure — no paired bookings.` Booked pairs preserve the existing closed-unrecorded path.
- Production reconciliation matched 17 eligible return legs at rollout; all 17 became cancelled with that reason. No past travel was marked completed.
- A separate hourly minute-15 watchdog records missed UTC invocations, impact, recovery and durable admin alerts. The clock history labels these `Missed — no invocation`.
- Two active Barefoot captains are linked to existing confirmed Auth accounts. Dave uses his own account; David uses the already-approved shared test mailbox. Actual OTP sign-in and switching require the mailbox holder.
- The 21 September T-24 issue was insufficient distinct captain capacity for three boats. The 24 September T-72 issue was a whole-party seat-minimum constraint. Neither is evidence of an allocation engine regression. Pending in-app notices do not establish an email dispatch failure; expired email notices were not replayed.

## Verification before rollout

- Node suite: 303 passed, one skipped; Vitest: 159 passed; production Next.js build passed.
- SQL return-leg behavior and missed-slot/watchdog fixtures passed in rollback-only transactions against the production database, followed by successful forward migration application.
- Migration grants restrict system functions to the service role and the history reader checks site-admin access. Existing Supabase security advisor findings unrelated to these migrations remain under review.

## Genuine-clock checks remaining

- Verify Vercel production deployment, the next hourly scheduler run and the independent watchdog at minute 15; inspect the alert delivery result. A missed run during a shared Vercel outage may only be detected after Vercel resumes.
- At 6 October 10:30 Antigua time, inspect the 9 October journey T-72 outcome. At 8 October 10:30 inspect T-24 and actual customer email receipt. On 9 October test recorded day-of-travel completion, then feedback, NPS and operator/captain quality propagation. The journey currently has two paid seats against a four-seat minimum, so a completed trip is contingent on additional bookings.
- A mailbox holder must verify the actual captain OTP and each identity choice. An operator must verify vehicle/captain assignment and reassignment through the live UI.
