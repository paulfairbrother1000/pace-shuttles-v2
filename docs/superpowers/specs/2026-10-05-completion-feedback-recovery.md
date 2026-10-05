# Pace V2 completion and feedback recovery specification

Approved priority scope, 5 October 2026.

- Preserve the approved T-72/T-24 allocation, discount and whole-party rules.
- Paired returns inherit their outbound booking population without creating duplicate commercial bookings. Completed outbound bookings still count as passengers of the return.
- Actual captain leg evidence determines travel status. Never manufacture travel, reopen cancelled journeys indiscriminately or infer completion from the scheduled time.
- Feedback invitations become due four elapsed hours after actual final completion, not next-day 10:00. An hourly job may deliver on its first invocation after that due time.
- Propagate feedback into operator scores using the existing configured 60% operator / 40% captain rating weights; platform NPS must not be counted as operator performance. Prevent legacy/new evidence from counting the same feedback twice.
- Report captain performance separately using existing authoritative average /5, response count and trend. Do not invent a new 0–100 captain ranking.
- Create one pending settlement accrual per genuinely completed allocation, using existing amounts and liability logic. Do not approve or pay it automatically.
- Preserve authorization checks and database transaction atomicity. Verify on a disposable database, never through mutating diagnostic calls against production.
- No new journeys, seats, fabricated captain records or manual email replay. Historical anomalous records require explicit reviewed repair evidence.
