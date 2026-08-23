# Pace Shuttles V2 — Customer Notifications & Journey Lifecycle

Production Supabase migration applied.

## Added
- Customer notification read/unread state.
- My Journeys unread-update count and mark-read controls.
- Immediate in-app update when Stripe payment is received.
- Immediate booking-confirmed update only after successful whole-party allocation.
- Automatic 24-hour and 3-hour journey reminders scheduled when a paid booking is allocated.
- Automatic cancellation and refund-complete updates.
- Existing T-72 at-risk and T-24 confirmed/action-required updates remain integrated.

## Important capacity rule
No notification or reminder reserves capacity. Capacity is consumed only by the post-payment whole-party allocation implemented in the previous tranche.

## Delivery
This tranche completes the in-app notification lifecycle. External email/SMS delivery requires a provider and delivery worker; notification records are already queued with channels/templates for that later integration.
