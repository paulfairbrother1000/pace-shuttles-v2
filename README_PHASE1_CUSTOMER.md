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
