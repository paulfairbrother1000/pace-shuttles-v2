# Route-Specific Vehicle Commercial Offers Design

## Purpose

Correct Pace Shuttles operator/vehicle administration so commercial pricing is route-specific rather than vehicle-wide.

A vehicle has physical and operational characteristics. Its commercial economics depend on the route it is offered on. Operators choose their own minimum journey revenue for each vehicle/route combination so that efficient or commercially aggressive operators can gain a competitive allocation advantage.

## Core model

The commercial hierarchy is:

`Operator -> Vehicle -> Route -> Route Offer`

A Route Offer is uniquely associated with one vehicle and one directional Pace Shuttles route.

A Pace Shuttles route is directional. `Antigua -> Barbuda` and `Barbuda -> Antigua` are different routes and therefore have independent Route Offers.

Each scheduled journey on a route comprises two operational legs. The Route Offer's minimum journey revenue is the minimum revenue the operator requires for the complete two-leg journey, not a per-leg price.

## Vehicle responsibility

Vehicle records describe facts intrinsic to the vehicle, including:

- operator
- vehicle type
- name/registration/description
- physical passenger capacity
- default captain where configured
- active/inactive status
- availability exceptions

Vehicle Admin must not ask for or present a universal minimum journey revenue as if it applied across every route.

Any legacy vehicle-level commercial defaults may remain temporarily for backward compatibility while existing data/functions are migrated, but they are not authoritative for new route pricing and must not be used by allocation when an applicable Route Offer exists.

## Route Offer responsibility

For each route a vehicle participates in, the operator configures a Route Offer containing:

- route
- vehicle
- active/participating status
- minimum seats
- maximum seats, never greater than vehicle capacity
- minimum journey revenue in USD for the complete two-leg journey
- preferred flag if retained by the allocation model
- minimum-value threshold override if configured
- post-minimum discount enabled/disabled
- maximum post-minimum discount

The operator sets minimum journey revenue manually. Pace Shuttles does not derive it from distance, fuel, crew time, or estimated operating costs.

Operator-facing help text for the field must say:

> Minimum revenue required for this vehicle to perform the complete two-leg journey on this route.

## Competitive allocation

The allocation/pricing engine consumes the Route Offer applicable to the departure's route. It must compare eligible active vehicle offers for that route and must not substitute a route-independent vehicle price.

The normal starting seat economics remain:

`base seat price = minimum journey revenue / minimum seats`

This is deliberately competitive. Two operators may enter different minimum journey revenues or minimum-seat thresholds for equivalent vehicles. Price remains a primary allocation input, with the existing quality and fairness rules continuing to apply where appropriate.

## Directionality and two-leg semantics

For `Antigua -> Barbuda`, an operator may configure Boat A with a $900 minimum journey revenue. That $900 covers the complete two-leg operational journey associated with the Antigua -> Barbuda route.

`Barbuda -> Antigua` is a different route. Boat A may have a different Route Offer and minimum journey revenue on it.

No automatic mirroring of commercial values between opposite-direction routes is required.

## Operator Admin UX

Operator Admin keeps Fleet and Route Offers as separate concepts.

### Fleet

Fleet displays vehicle facts and availability only. Creating a vehicle must not require the operator to invent a universal journey price.

### Route Offers

Route Offers is the commercial participation area. A row should communicate, at minimum:

`Route | Vehicle | Min / max seats | Minimum journey revenue | Discount | Status | Controls`

Creating an offer follows:

1. select an eligible route;
2. select one of the operator's compatible vehicles;
3. enter minimum seats;
4. enter maximum seats within vehicle capacity;
5. enter minimum journey revenue for the complete two-leg journey;
6. configure optional threshold/discount controls;
7. activate the offer.

Editing an offer changes future allocation calculations. Existing confirmed allocations and their financial snapshots must not be retrospectively repriced.

## Site Admin UX

Site Admin can see the same vehicle/route commercial offers for an operator and can create/manage them through protected admin functions.

The existing Operator Detail screen should distinguish Fleet from Route Offers. The current `Route Assignments` wording should become `Route Offers` because the record is a commercial offer, not merely a route linkage.

Site Admin should not be encouraged to copy a vehicle-level default minimum revenue into a new offer. The route-specific values must be explicitly entered for that offer.

## Compatibility rules

A Route Offer may only pair:

- a vehicle belonging to the operator represented by the offer;
- an active/eligible vehicle;
- a route that permits the vehicle's vehicle type;
- a vehicle type approved for that operator where operator/type approval is enforced.

`max_seats` must not exceed the vehicle's physical capacity. `min_seats` must be positive and no greater than `max_seats`. Minimum journey revenue must be positive.

## Uniqueness and auditability

There must be only one current active commercial offer for a given `vehicle + route` combination.

Commercial changes must remain auditable. At minimum, allocation/consideration records must retain the commercial values used for that allocation calculation so later edits cannot rewrite historical decision evidence. If the existing Route Offer persistence supports effective dating/versioning, preserve historical versions rather than overwriting history.

## Allocation and downstream snapshots

When a departure is evaluated, its vehicle consideration must snapshot the applicable Route Offer values needed by the engine, including minimum seats, maximum seats, minimum journey revenue, threshold and discount configuration.

Confirmed allocation, journey value, commission and settlement calculations continue from the allocation/financial snapshots already created for that journey. Editing a Route Offer affects future evaluations, not already confirmed commercial obligations.

## Migration

Existing route-offer rows are the preferred source for current commercial configuration because the application already exposes `v2_vehicle_route_offers` / `v2_operator_my_route_offers` and route-offer update functions.

Existing vehicle-level `default_min_seats`, `default_max_seats`, `default_min_revenue_cents`, threshold and discount fields must be treated as legacy defaults, not route-independent authoritative pricing.

Migration must avoid silently changing live economics. Existing Route Offers retain their stored values. Vehicles without Route Offers are not automatically made commercially eligible for every route; an explicit Route Offer is required.

## Testing and acceptance

The change is accepted when:

1. A vehicle can be created/administered without entering route-independent minimum journey revenue.
2. The same vehicle can have materially different commercial offers on two routes.
3. Opposite-direction routes can have independent offers.
4. Route Offer maximum seats cannot exceed vehicle capacity.
5. Duplicate current active offers for the same vehicle/route are rejected.
6. Allocation for a route uses that route's offer values and not the vehicle's legacy defaults.
7. Editing an offer does not change already confirmed journey/allocation financial snapshots.
8. Operator Admin clearly explains that minimum journey revenue covers the complete two-leg journey.
9. Site Admin shows Route Offers separately from Fleet and does not auto-copy a universal vehicle price.
10. Existing live Route Offers continue to work without silent repricing.
