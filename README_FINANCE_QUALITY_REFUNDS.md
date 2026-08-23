# Pace Shuttles V2 — Finance, Refunds & Quality Operations

Production Supabase migration: APPLIED.

## Site Admin Finance
- Customer refund operations queue
- Approve/reject requested refund amounts
- Record provider-paid refunds with provider reference
- Existing settlement/liability controls retained
- Stripe/payment reconciliation event visibility
- Ledger balances and operator liability exposure retained

## Quality Operations
- Customer feedback visible to Site Admin
- Review/attribute feedback to Operator / Pace Shuttles / Customer / External / Unassigned
- Quality evidence count surfaced
- Attribution review refreshes operator quality score

## Customer
- Eligible future bookings can be cancelled from the customer workspace
- Customer chooses requested refund amount up to booking total and supplies a reason
- Protected backend verifies signed-in ownership and journey/booking status

## Safety / controls
- Refund approval cannot exceed requested amount
- Paid refunds require a provider reference
- Customer cancellation cannot operate on active/completed/cancelled journeys
- All Site Admin finance functions require Site Admin role
