# Pace Shuttles V2 implementation status — first UI tranche

## Implemented

- Shared responsive design system and central CSS tokens.
- Desktop Site Admin shell and mobile bottom navigation.
- Global Dashboard with revenue, journeys, passengers, commission, average commission rate, average revenue/trip, average operator revenue/trip, load factor, rankings and exception panels.
- Live Operations with journey status cards/table and journey-type text.
- Journey Detail with passengers, allocation competition, operator/vehicle/captain, financials, timeline and actions.
- Performance Analytics with geography, route, operator and destination metrics.
- Operator list/detail and Site Admin “Manage as Operator” context.
- Operator readiness/setup progress and quick onboarding actions.
- Finance & Settlements foundation.
- Network Management foundation.
- Support & Administration foundation.
- Operator, Captain and Customer mobile foundations.
- Supabase `pace_v2` client adapter and read-model loader functions with safe mock fallback.

## Next engineering tranche

- Auth and role-aware route guards.
- Replace remaining mocks with the final reporting/API read models.
- Real-time subscriptions for Live Operations.
- Operator CRUD (vehicles, captains, route offers, availability) and audited acting-admin mutations.
- Finance mutations, settlement workflow and Stripe server actions.
- Customer quote/booking/payment path.
- Captain start/end/voyage-log mutations and PWA offline cache.
- End-to-end tests and deployment pipeline.


## Finance administration tranche
- Site-admin settlement control view is now wired to live V2 settlement data.
- Finance screen shows journey value, Pace commission, net payable and open operator liability exposure.
- Site Admin can apply operator liabilities, approve settlements, mark approved payouts as sent, and reconcile sent/paid settlements.
- Ledger account balances are surfaced for finance reconciliation.
- Protected public RPC wrappers enforce Site Admin authorization and call the existing V2 finance business functions.
