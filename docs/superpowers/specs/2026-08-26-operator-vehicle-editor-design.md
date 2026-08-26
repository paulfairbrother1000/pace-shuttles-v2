# Operator Vehicle Editor Design

## Purpose

Replace the prompt-driven Pace Shuttles operator fleet and Route Offer administration with one clear vehicle editor. Selecting an existing vehicle opens every relevant vehicle field and all of that vehicle's Route Offers. Adding a vehicle opens the same editor with blank, editable values.

This design extends the approved route-specific commercial model in `docs/superpowers/specs/2026-08-25-route-specific-vehicle-commercial-offers-design.md`.

## User experience

The Fleet & Availability workspace has a vehicle list and a full editor. Selecting a vehicle loads its profile and Route Offers. `Add vehicle` opens a blank draft in the same editor.

The editor contains:

- vehicle name;
- Transport Type;
- physical passenger capacity;
- default/preferred captain;
- description and image where supported;
- active/inactive status;
- all Route Offers attached to the vehicle;
- save, cancel and deactivate controls.

The operator can add or remove Route Offers without leaving the vehicle editor. Changes remain local to the draft until `Save changes` succeeds. Cancel discards the complete unsaved draft.

Existing availability exceptions remain supported. Their current date-blocking workflow may remain adjacent to the editor and does not need to be redesigned as part of this feature.

## Vehicle creation and editing

Creating and editing use one form and one validation model.

For a new vehicle, fields are blank except safe presentation defaults. Transport Type and preferred captain are dropdowns. The captain dropdown contains active captains belonging to the signed-in operator and compatible with the selected Transport Type where captain/type qualification is configured.

The preferred captain is stored through `vehicle_captain_preferences`, not as free text. Selecting no captain removes or deactivates the vehicle's current default preference. The first active preference is treated as the default for automatic captain selection.

Vehicle capacity is a physical constraint. Every Route Offer maximum seat value must be no greater than the vehicle capacity. Reducing capacity below an attached offer's maximum seats blocks saving and identifies the affected offer.

## Route Offer cards

Each Route Offer is shown as an editable card containing:

- route;
- minimum seats;
- maximum seats;
- minimum journey revenue in USD for the complete two-leg journey;
- whether post-minimum discounts apply;
- maximum post-minimum discount percentage;
- below-minimum operating mode;
- operating threshold percentage where required;
- active status and remove control.

Discount percentage is enabled only when post-minimum discounts are enabled. Turning discounts off clears the submitted discount basis points to zero.

The below-minimum operating modes are explicit:

1. `never` — do not operate when minimum journey revenue is not met;
2. `route_default` — use the route's configured minimum-value threshold;
3. `custom_threshold` — operate when revenue reaches the operator-entered percentage of minimum journey revenue.

`custom_threshold` requires a percentage greater than 0 and no greater than 100. The stored ratio is the percentage divided by 100. A null ratio means `route_default` only; it must not also mean `never`.

The database therefore requires an explicit below-minimum mode on Route Offers rather than overloading `min_value_threshold_ratio`. Existing rows with a non-null threshold migrate to `custom_threshold`; existing rows with a null threshold migrate to `route_default`. No existing offer is silently changed to `never`.

## Adding a route

`Add route` opens a searchable route selector. Eligible routes are determined automatically and the operator is not asked to enter an operating country or city on the vehicle.

A route is eligible only when:

- it is active;
- it permits the vehicle's selected Transport Type;
- it is not already attached to the vehicle draft;
- it is within the signed-in operator's existing operating geography.

For a normal or small country, only routes in the operator's country are shown. For a country configured as large, only routes in the operator's city are shown. The filtering must use the existing operator/geography and country hierarchy configuration as the authoritative source; the client must not accept an arbitrary country or city supplied by the operator.

The server-side create/update operation rechecks all compatibility and geography rules. Client-side filtering is for usability, not authorization.

Selecting a route adds a blank Route Offer card to the draft. The operator completes its commercial fields before saving. `Save and add another route` may keep the selector open for rapid configuration.

If Transport Type changes, attached offers that are no longer compatible are flagged. Save is blocked until they are removed or the Transport Type is restored.

## Save semantics

The editor saves one aggregate draft: vehicle facts, preferred captain and Route Offer additions, edits and removals. The database applies the aggregate change atomically so a partially updated vehicle is never exposed if one part fails validation.

For an existing offer, `Remove` means deactivate/end the current offer rather than erase commercial history. For a newly added unsaved card, `Remove` only removes it from the draft.

Editing Route Offers affects future allocation evaluations only. Confirmed allocations and historical commercial snapshots are never repriced.

The save operation is operator-scoped and derives the operator identity from the authenticated membership. It does not trust a client-supplied operator ID. Operators cannot edit another operator's vehicles, captains, preferences or offers.

## Data contract

The operator vehicle-editor read model must return:

- operator-scoped vehicle records and Transport Type details;
- active operator captains and their compatible Transport Types;
- each vehicle's active preferred captain;
- every current Route Offer and its route label, seat values, minimum revenue, discount settings and below-minimum mode;
- eligible routes for the selected vehicle type, already restricted by operator geography;
- enough stable IDs to submit edits without relying on display labels.

The write contract accepts one structured payload for the aggregate draft and returns the saved vehicle ID. It validates field types, capacity, duplicate vehicle/route pairs, route/type compatibility, operator/type approval, captain ownership/qualification, geography, discount consistency and below-minimum mode consistency.

## Responsive and accessible behaviour

On wide screens, the fleet list and editor can appear side by side. On narrow screens, the fleet list becomes a vehicle selector or stacked list above the editor. Route Offer cards stack their fields rather than requiring horizontal table scrolling.

Every input has a visible label. Validation messages identify the specific field or Route Offer. Destructive controls require confirmation for persisted records. Keyboard focus moves into a newly opened editor or route selector and returns to the triggering control when cancelled.

## Acceptance criteria

1. Clicking a vehicle opens one attractive form containing all relevant vehicle fields and Route Offers.
2. Adding a vehicle opens the same blank, editable form.
3. Transport Type and preferred captain are appropriate dropdowns.
4. A preferred captain must belong to the operator and satisfy configured Transport Type qualification.
5. `Add route` shows only active, compatible, unattached routes in the operator's country, or operator's city for large countries.
6. The form does not ask the operator to re-enter country or city.
7. Each Route Offer exposes seats, complete-journey minimum revenue, discount controls and explicit below-minimum operation behaviour.
8. `never`, `route_default` and `custom_threshold` are unambiguous in storage and UI.
9. Vehicle capacity and Route Offer values are validated both in the form and database.
10. Saving the aggregate draft is atomic and operator-scoped.
11. Removing an existing offer preserves history and does not reprice confirmed allocations.
12. The editor remains usable on desktop and mobile and replaces browser prompts for vehicle/offer administration.
