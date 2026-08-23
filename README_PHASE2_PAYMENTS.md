# Phase 2 — Customer payments

This tranche connects a reserved Pace Shuttles booking to Stripe Checkout.

## Vercel environment variables
- STRIPE_SECRET_KEY
- STRIPE_WEBHOOK_SECRET
- SUPABASE_SERVICE_ROLE_KEY
- existing NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY

## Stripe webhook
Configure the Stripe webhook endpoint as `/api/stripe/webhook` and subscribe to `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `checkout.session.async_payment_failed`, and `payment_intent.payment_failed`.

The database migration `phase2_stripe_customer_payment_foundation` has already been applied to Supabase.
