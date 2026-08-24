# Pace Shuttles V2 — Site Admin completion / shell correction

The current repository already contains the large Site Admin functional tranche in `components/pages.tsx`.
That code includes the protected operational and commercial controls required for end-to-end testing, including:

- Journey detail, bookings and allocations
- Captain assignment / auto-assignment
- Live consideration refresh
- Manual T-72 and final T-24 controls
- Operator cancellation/liability registration
- Customer cancellation/refund requests
- Revenue rescue controls
- Scheduler/audit visibility
- Network hierarchy and route configuration
- Operators, vehicles, captains and commercial offers
- Commission configuration and overrides
- Finance / settlement / reconciliation
- Support inbox and replies
- Notifications
- Quality evidence and customer feedback
- Services / recurring schedule generation
- User access linking for Site Admin, Operator and Captain accounts

## Why this tranche is intentionally small

The Site Admin functionality is already present in the current main branch. Replacing it with another duplicate dashboard would create regression risk.

The important remaining correction is the shared shell:
the existing `AdminShell` always renders the complete Site Admin navigation, even when used by `/operator` and `/captain`.

This tranche replaces `components/ui.tsx` so:
- `/admin/*` retains the complete Site Admin navigation.
- `/operator` receives only the Operator Dashboard shell.
- `/captain` receives only the Captain Dashboard shell.
- Operator and Captain users are not shown Site Admin navigation links.
- Site Admin mobile navigation remains unchanged.
- Role-aware route protection from the previous access tranche remains the security boundary.

## File to replace
`components/ui.tsx`

## Database
No migration required.

## Next stage
After this commit/deployment, the four interfaces are ready for structured end-to-end test:
1. Customer
2. Operator
3. Captain
4. Site Admin

Testing should then cover booking/payment, allocation T-72/T-24, recurring service generation, operator/captain actions, customer My Journeys, emails/notifications, refunds/cancellations, finance and support.
