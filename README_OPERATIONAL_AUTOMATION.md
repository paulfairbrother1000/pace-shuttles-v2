# Pace Shuttles V2 — Operational automation

This tranche makes the existing T-72/T-24 operational engine run automatically.

## What it does
- Runs once per hour through Vercel Cron.
- Processes due T-72 journeys through the existing `process_departure_t72` engine.
- Processes due T-24 journeys through the existing `process_departure_t24` engine.
- Extends the generated departure horizon continuously so recurring schedules remain bookable into the future.
- Existing T-72/T-24 customer/operator notifications are queued by those engine functions.
- Adds an admin-only automation-health view in Supabase for overdue T-72/T-24 work, failures, due notifications and booking horizon.

## Vercel setting required
Add `CRON_SECRET` as a long random value. Vercel sends it as `Authorization: Bearer <CRON_SECRET>` when invoking cron routes.

`SUPABASE_SERVICE_ROLE_KEY` must also remain configured because this endpoint is a trusted system operation.

## Capacity rule
This tranche does not change customer capacity handling. Unpaid orders do not consume seats. Whole-party allocation remains post-payment.
