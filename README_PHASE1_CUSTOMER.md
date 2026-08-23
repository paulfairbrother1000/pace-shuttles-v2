# Pace Shuttles V2 — Phase 1 Customer Booking Experience

This tranche moves the V2 root from an admin redirect to the public Pace Shuttles booking experience while preserving the established customer design language from the current Pace Shuttles site.

## Included
- Public Pace Shuttles homepage / booking planner at `/` and `/book`
- Existing dark navy consumer theme, white top navigation, imagery-led country tiles, rounded cards and blue actions
- Live V2 countries and future departures from protected public database views
- Destination, pickup, date and party-size filtering
- Live V2 allocation/pricing quotes using the same progressive allocation engine as operations
- Whole-party pricing; no party splitting
- USD all-in customer pricing with configured country tax and customer fees
- 15-minute quote intent before T-72
- Customer checkout at `/checkout`
- Secure sign-in before committing a reservation
- Lead passenger and passenger-name capture
- Reservation creates V2 order + preliminary booking and leaves payment `pending` for Phase 2 Stripe integration
- Existing `/admin`, `/operator`, `/captain` and `/customer` workspaces remain authenticated

## Database
The `phase1_public_booking_experience` migration has already been applied to the V2 Supabase project. Do not rerun SQL manually.

## Deployment
Overlay this folder onto the repository root and commit to `main`.

## Phase 1 final booking-flow tranche — 23 Aug 2026

- Journey discovery now separates schedule discovery from live pricing: recurring departures display quickly with a **Check price** action.
- Clicking **Check price** calls the shared V2 pricing/allocation engine for the selected whole party.
- Successful live offers show all-in per-seat and party totals and progress to a held quote.
- Sold-out whole-party and fairness-tie states are shown explicitly rather than as generic failures.
- The planner surfaces the next available dates for the selected destination/pick-up and retains date, type and party filters.
- Checkout now validates lead and passenger names, supports passenger age groups, displays a live quote-hold countdown, handles expiry, and preserves the whole-party-not-split rule.
- Payment remains intentionally pending until Phase 2 Stripe integration.

### V1 filter behaviour correction
After a country is chosen, destination is optional. The planner immediately lists all currently scheduled journeys for that country. Destination, pickup, date and vehicle type act as independent filters. Selecting only a date shows every journey running in the chosen country on that day, matching the V1 discovery behaviour.
