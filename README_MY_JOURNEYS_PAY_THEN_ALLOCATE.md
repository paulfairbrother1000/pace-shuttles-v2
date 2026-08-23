# My Journeys / pay-then-allocate tranche

Business rule implemented: unpaid checkout never consumes seats.

Flow: quote -> customer/passenger details -> pending order/booking -> Stripe payment -> atomic whole-party availability re-check -> allocation -> booked journey.

If payment succeeds but whole-party capacity has disappeared, the booking is cancelled and a full automatic Stripe refund is created and recorded. My Journeys exposes awaiting payment, allocating seats, booked, refund processing and refunded states. Only booked journeys count toward seats booked.

Database migrations were applied directly to the connected Supabase project. The matching SQL logic is represented by the deployed database functions; application changes in this tranche update checkout copy, webhook allocation/refund handling, payment success status and My Journeys.
