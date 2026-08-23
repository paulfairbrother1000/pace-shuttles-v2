# Pace Shuttles V2 — Authentication & Checkout Continuity

This tranche fixes authentication interrupting the customer booking journey.

## Behaviour

- The selected quote, lead passenger, email and passenger manifest are saved locally in the customer's browser before authentication.
- A magic-link return lands back on the exact `/checkout?q=...` URL and restores the entered details.
- Existing users can sign in with a password from checkout, avoiding an authentication email entirely.
- Magic-link resend is throttled in the UI to reduce accidental repeated requests.
- If the 15-minute price expires during authentication, Pace Shuttles obtains a fresh live quote for the same departure and party, changes the quote id in the URL and carries the passenger details forward. The customer does not restart the search or retype details.
- Browser checkout data is removed once the order is created and is considered stale after 30 minutes.
- Authentication still reserves no seats. Whole-party capacity is allocated only after successful payment.

## Passenger manifest correction

`party_size` includes the lead passenger. A two-seat booking therefore displays the lead passenger plus one additional passenger, not the lead passenger plus two additional people. The lead passenger is also included in the passenger payload sent to the booking function.

## Production authentication email

Do not use Supabase's default mail sender in production. Configure custom SMTP in Supabase Auth using a transactional provider and set production rate limits appropriate to expected traffic. SMTP credentials are secrets and should be entered directly in Supabase/Vercel, never committed to this repository.
