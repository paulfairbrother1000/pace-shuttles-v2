# T-72 captain resource reservations design

## Objective

Prevent Pace Shuttles from selling, retaining or confirming more simultaneous vehicles than its operators can staff with distinct eligible captains. A captain who is committed to one complete duty must not be counted for another overlapping duty. When no alternative captain exists, the affected vehicle is removed from that journey and every other overlapping journey rather than allowing the lifecycle to stop silently at T-24.

The resource rule applies to the complete duty: outbound departure through return arrival, plus a 30-minute turnaround allowance. A later duty may reuse the captain only when its resource window begins after that allowance.

## Confirmed current behaviour and gap

The current production design already:

- requires every active operator to retain at least one active captain;
- requires every active vehicle to have an explicitly configured eligible default captain;
- requires a distinct eligible captain for every vehicle retained inside one proposed departure;
- excludes captains who already have an active assignment on an overlapping confirmed allocation;
- stops T-24 for manual review when confirmed boats outnumber eligible captains.

It does not yet reserve a captain before confirmation. Two overlapping departures that are both preliminary or under consideration can therefore count the same captain. The existing resource window also has no turnaround allowance, and it can cover the return leg only when an explicit journey pair exists.

Production currently has no `journey_pairs`, `service_return_designs` or `route_return_mappings`. Return duties must therefore be configured explicitly; this change must not infer a return from similar route names or times.

## Approaches considered

### 1. Assign the captain permanently at T-72

Reuse `captain_assignments` and create the final assignment at T-72. This is superficially simple, but it changes the established meaning of a confirmed assignment, exposes an unconfirmed resource through captain and customer interfaces, and complicates T-24 replacement and communications.

### 2. Recalculate availability without persisting a claim

Run a cross-departure matching query whenever availability is requested. This improves forecasts but does not prevent two checkout or scheduler transactions from simultaneously counting the same captain. Advisory locks reduce the race but provide no durable operational evidence or clear release history.

### 3. Persist staged captain reservations (selected)

Create a private captain-resource reservation for each vehicle that carries paid demand. Reservations progress from provisional, to held at T-72, to confirmed at T-24. An exclusion constraint makes overlapping active reservations for the same captain impossible at the database boundary. This separates operational resource commitment from the captain-facing confirmed assignment while providing the strongest concurrency guarantee and an auditable release path.

## Resource reservation model

Add a private `pace_v2.captain_duty_reservations` table with:

- reservation identity;
- departure and vehicle-consideration identity;
- operator, vehicle and captain identity;
- the calculated duty start and end timestamps;
- state: `provisional`, `held_t72`, `confirmed_t24` or `released`;
- creation, promotion and release timestamps;
- release reason and the allocation/assignment identity when confirmed;
- source and engine version for audit.

The active states are `provisional`, `held_t72` and `confirmed_t24`. A partial GiST exclusion constraint over `captain_id` and the half-open duty range `[start, end)` prevents overlapping active reservations for one captain. A partial unique constraint permits only one active reservation for a vehicle consideration. The table has RLS enabled, no anonymous or general authenticated grants, and is changed only through protected internal functions.

`captain_assignments` remains the source of confirmed captain identity for the captain interface, customer communications and journey operations. At T-24, the engine creates or validates that assignment from the reservation and links both records.

## Duty window

`captain_duty_resource_window` will return the complete scheduled duty followed by a 30-minute turnaround allowance:

- paired journey: outbound departure through return scheduled arrival, plus 30 minutes;
- one-way journey: departure through scheduled arrival, plus 30 minutes;
- missing scheduled arrival: retain the existing conservative eight-hour fallback, then add the allowance.

All availability, reservation, assignment and conflict projections must use the same helper. Journey pairing remains explicit and must be completed through the existing Site Admin return-design workflow.

## Before T-72: paid-demand protection

Captain capacity must be considered before a customer is allowed to rely on a vehicle:

1. Live-offer and checkout-capacity functions include active captain reservations and confirmed captain assignments when determining whether adding the party can be staffed.
2. When a paid booking causes a vehicle consideration to carry demand for the first time, the allocation transaction creates a provisional reservation for a specific eligible captain.
3. If existing provisional reservations can be rematched to preserve all paid demand, the transaction may reassign them atomically using deterministic captain priority.
4. If no complete match exists, the candidate vehicle is not offered. A checkout/payment race is rechecked inside the commit transaction; the established pay-then-allocate recovery/refund path handles a payment that cannot be fulfilled.
5. Releasing the final paid party from a vehicle releases its provisional reservation.

This deliberately reserves a scarce captain only when paid demand activates a vehicle, not for every catalogue listing or abandoned quote.

## T-72 processing

The T-72 processor performs vehicle allocation and captain reservation in one transaction:

1. Lock the departure and the relevant captain-resource identities in deterministic order.
2. Rebalance whole booking parties using vehicle capacity, revenue thresholds and active captain availability.
3. Produce both the winning vehicle set and an injective vehicle-to-captain mapping.
4. Promote the surviving reservations to `held_t72`, creating or rematching them where necessary.
5. Release reservations for vehicles no longer carrying demand.
6. Mark unstaffable vehicle considerations `discarded_t72` with a structured `captain_conflict` reason. This is a Pace Shuttles resource decision, not an operator voluntary withdrawal and must not create operator-withdrawal liability.
7. Suppress the affected vehicle immediately from all other overlapping live offers. At those departures' T-72 processing, the same rule either finds another captain or records the same discard reason.
8. Re-run booking coverage. If every paid party is covered, continue to under-consideration communications. If not, mark the departure and affected bookings at risk, create a high-priority operational alert and do not send a misleading vehicle-under-consideration email for an unstaffable vehicle.

T-72 processing remains idempotent. Re-running it returns the existing valid holds or safely rematches invalid ones; it never creates duplicate reservations.

## T-24 confirmation

At T-24 the engine:

1. locks and revalidates every held reservation;
2. confirms vehicle allocations;
3. creates the active `captain_assignments` from the reserved captain identities;
4. promotes the reservations to `confirmed_t24` and links the allocation and assignment;
5. queues operator, captain and customer confirmations only after all required resources are confirmed.

If a reserved captain has become inactive, ineligible or otherwise unavailable, T-24 first attempts an atomic rematch. If no complete rematch exists, it stops for manual review, retains or creates the high-priority alert and sends the approved captain-pending customer communication. It must not partially confirm a departure or silently omit communications.

## Release and change handling

An active reservation is released when:

- its vehicle consideration loses its final qualifying paid allocation;
- the vehicle or route offer becomes inactive or ineligible;
- the operator replaces or withdraws the vehicle before the applicable deadline;
- the departure is cancelled;
- a Site Admin performs an authorised replacement;
- the confirmed duty completes or is closed through an authorised lifecycle path.

Release records the reason and timestamp. Released reservations remain as audit evidence but no longer block the captain. Any replacement operation must acquire the new reservation before releasing the old one so a failed replacement cannot leave the journey unstaffed.

## Operator and Site Admin presentation

No new operator action is required for a normal journey. Existing under-consideration emails continue to name the vehicle and planned captain, but only after the T-72 hold exists.

Site Admin conflict detail distinguishes:

- no eligible captain configured;
- captain already reserved for an overlapping journey;
- complete duty/return overlap;
- turnaround overlap;
- captain became inactive or ineligible;
- manual review required because paid parties cannot be covered.

The admin journey board shows the conflicting journey identifier without exposing customer data.

## Existing 20 and 21 September journeys

The migration must not fabricate reservations for already-past T-72 decisions unless a complete valid mapping exists. It will audit future/open vehicle demand, create reservations only for conflict-free mappings, and raise operational alerts for unresolved shortages.

The 20 September St John's to Nikki Beach journey remains an operational exception: 29 paid seats cannot be covered by its currently available distinct captain capacity. Code cannot manufacture the missing resource; an additional eligible captain/vehicle or an authorised customer-resolution decision is still required.

The 21 September confirmed journey is revalidated against any overlapping open journey before activation. Existing confirmed captain assignments take precedence over provisional or T-72 reservations.

## Security and concurrency

- Reservation data remains in the private `pace_v2` schema with RLS enabled and no direct client grants.
- New internal mutation functions use a fixed empty or explicit search path and are revoked from `PUBLIC`, `anon` and `authenticated`.
- Only existing trusted service operations and protected Site Admin workflows can invoke lifecycle mutations.
- Advisory locks serialize the planning transaction, while the exclusion constraint is the final protection against races.
- Existing allocation and assignment triggers continue to validate operator, vehicle type and route eligibility.
- The migration must run Supabase security and performance advisors before release.

## Verification

Automated contract and executable database tests must prove:

- one captain cannot hold two overlapping provisional, T-72 or T-24 duties;
- the same captain can serve a later non-overlapping duty after the turnaround allowance;
- a return leg extends the resource window through return arrival;
- paid demand creates and releases provisional reservations correctly;
- simultaneous checkout/allocation attempts cannot commit conflicting captain claims;
- deterministic rematching preserves all staffable paid demand;
- an unstaffable vehicle is removed from live offers and becomes `discarded_t72` with `captain_conflict` at T-72;
- the operator under-consideration email is queued only for held resources;
- T-24 consumes the held captain and creates the matching confirmed assignment;
- an invalidated captain is rematched or produces manual-review and captain-pending evidence;
- cancellation, replacement and completion release reservations without opening a race;
- RLS and function grants deny anonymous, customer, operator and captain mutation access;
- existing one-way, return-pair, allocation, scheduler, communications and captain-Today tests remain green.

Release verification also requires the complete Node and component test suites, a production build, an executable preview-database scenario, Supabase advisors, and a production scheduler run after deployment. Live database activation and backfill require explicit approval after preview evidence is reviewed.
