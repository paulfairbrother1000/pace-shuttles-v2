# Pace Shuttles V2 — Large Operations Tranche

This tranche extends the deployed V2 administration build into the three operational workspaces.

## Operator
- Trips under consideration with live allocation position and withdrawal deadline
- Protected operator withdrawal action (confirmed allocations cannot be withdrawn)
- Fleet availability blocks and restoration
- Route participation pause/activate
- Confirmed journeys, commission, earnings and settlement state
- Quality score/NPS evidence and fairness win/loss visibility

## Captain
- Journey selection and operational status
- Start/complete journey using protected V2 functions
- Normal/abnormal completion, voyage notes and incident capture
- Passenger manifest scoped to signed-in captain
- Journey operational messages

## Customer
- Booking and departure status
- Payment state, seats and value
- Journey notification body/status display

## Platform hardening
- Exact duplicate pending notification cleanup and live de-duplication index
- Role-scoped public API views
- Protected operator self-service functions using authenticated operator membership

The production Supabase migration has already been applied.
