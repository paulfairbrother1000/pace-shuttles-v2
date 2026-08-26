# Service-specific vehicle offers

## Purpose

An operator must offer a vehicle to a recurring scheduled service, not merely to a geographic route. The interface and allocation engine must distinguish, for example:

- Jolly Harbour → Nobu — Saturday at 10:00
- Jolly Harbour → Nobu — Tuesday at 11:00

Each scheduled service may have different eligible vehicles, commercial terms, seat limits, captain override, discount policy, and below-minimum operating rule.

## Domain model

`routes` continues to describe the geographic two-leg journey. `services` continues to describe a recurring schedule for a route, including local days of week, departure time, timezone, and validity dates. `vehicle_route_offers` remains the versioned commercial-offer table but gains a required `service_id` relationship after migration.

A current offer is unique by `(vehicle_id, service_id)`, rather than `(vehicle_id, route_id)`. `route_id` remains on the offer as denormalized provenance and is constrained to match the selected service's route. This preserves existing reporting and limits the impact on historical consumers.

## Existing data migration

The migration adds nullable `service_id`, backfills every current and historical offer where its route has exactly one service, and validates that all offers were resolved before making the column required.

The live inspection on 26 August 2026 found no route with more than one active service, so current live offers have an unambiguous schedule target. The migration must still fail safely with a descriptive exception if ambiguous or missing mappings exist when it is run; it must not guess or silently duplicate commercial offers.

The old current-offer uniqueness index on `(vehicle_id, route_id)` is replaced by a partial unique index on `(vehicle_id, service_id)` for offers whose `effective_to` is null. Historical offer versions remain valid.

## Operator interface

The eligible-offer loader returns `service_id`, route name, `days_of_week`, local `departure_time`, and timezone. The operator vehicle editor uses `service_id` as the option value and attachment identity.

Labels use a human-readable schedule:

`Jolly Harbour → Nobu — Saturday at 10:00`

If a service contains several days at the same time, they are shown together, for example:

`Jolly Harbour → Nobu — Monday, Wednesday, Friday at 11:30`

The same schedule appears in the attached journey card. Existing country/locality and transport-type eligibility filters continue to apply. An operator may attach the same vehicle to multiple services on the same route, but never twice to the same service.

The save payload sends both `service_id` and `route_id`. The database derives and validates the route from the service; it does not trust an inconsistent client pair.

## Allocation behavior

When considerations are refreshed for a departure, eligible offers must match `vehicle_route_offers.service_id = departures.service_id`. Matching by route alone is removed. Therefore a vehicle offered for Saturday at 10:00 is not considered for Tuesday at 11:00 unless the operator created a separate offer for that service.

Commercial and captain values continue to snapshot from the selected versioned offer into `vehicle_considerations`. Existing confirmed allocations and historical consideration records retain their offer references and are not rewritten.

## Database APIs and security

The operator editor route RPC/view includes only active services whose route, country/locality, transport type, and operator authorization are eligible under the existing rules.

The aggregate save function validates:

- the service exists and is active;
- the supplied route matches the service route;
- the route and operator are geographically compatible;
- the vehicle and route share the approved transport type;
- the operator has access to the vehicle;
- only one current offer exists for the vehicle/service pair;
- existing capacity, pricing, captain, discount, and threshold rules still pass.

Authorization remains based on `has_operator_access`; no new public table access is introduced. Updated public RPCs/views remain restricted to authenticated users and protected by their existing operator checks.

## Compatibility

Existing display and reporting fields retain `route_id` and `route_name`. New fields are additive: `service_id`, `service_days_of_week`, `service_departure_time`, and `service_timezone`.

Any allocation function or view that currently joins an offer to a departure using only `route_id` must be updated to use `service_id`. SQL contract tests will scan the active definitions to prevent route-only matching from returning.

## Testing and verification

Automated tests must cover:

- two services with the same route appearing as separate selectable options;
- day/time formatting for one and multiple weekdays;
- a vehicle being attachable to both services independently;
- duplicate offers for one vehicle/service being rejected;
- an inconsistent route/service pair being rejected;
- consideration refresh selecting only offers for the departure's service;
- current live offers migrating without changing their commercial values;
- existing captain, capacity, discount, threshold, geographic, and transport-type behavior;
- mobile presentation without clipped schedule or captain controls.

Verification includes the full Node and Vitest suites, a production Next.js build, live migration contract queries, rollback-wrapped behavioral SQL for two services on one route, and confirmation that the exact production commit reaches Vercel READY.
