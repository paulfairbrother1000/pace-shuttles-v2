# Pace Shuttles V2 — Operator Interface Completion

This tranche replaces the single long operator view with a usable operational dashboard while reusing the protected V2 operator APIs already present.

## Includes
- Overview KPIs and upcoming operational work.
- Trips Under Consideration, including controlled withdrawal where still permitted.
- Trips Confirmed (non-withdrawable operational view).
- Trips Completed and operator earnings / commission visibility.
- Fleet and date-specific unavailability management.
- Route participation / commercial offer editing.
- Post-minimum discount controls.
- Quality score visibility.
- Allocation fairness ledger visibility.
- Mobile-responsive behaviour inherited from the existing dashboard CSS.

## Files
Replace:
- `app/operator/page.tsx`
Add:
- `components/operator-dashboard.tsx`

## Database
No migration required. It uses the existing operator-scoped views and protected RPCs. The previous role-aware access tranche ensures `/operator` is only accessible to a user with an active operator membership.

## Important business rules retained
- Operators may withdraw only while a journey remains under consideration.
- Confirmed allocations are not withdrawable through this dashboard.
- Operator offer changes feed the same live allocation/pricing engine as customer booking.
- Customer bookings are not created / seats are not consumed until successful payment.
