# Pace Shuttles V2 — Captain Interface Completion

This tranche turns the captain route into a focused mobile-first operational workspace.

## Includes
- Assigned journey list.
- Ready / active / completed status.
- Start journey control records actual departure.
- Complete journey control records actual arrival.
- Voyage notes and abnormal-completion / incident summary.
- Passenger manifest for the selected allocation.
- Passenger operational messaging:
  - late running
  - pickup update
  - weather / conditions
  - operational update
- Journey-message history.
- Captain operating guidance.

## Files
Replace:
- `app/captain/page.tsx`

Add:
- `components/captain-dashboard.tsx`

## Database
No new migration is required. This tranche uses the existing captain-scoped views and protected RPCs already in V2:
- `v2_captain_my_journeys`
- `v2_captain_my_manifest`
- `v2_captain_my_messages`
- `v2_captain_start_journey`
- `v2_captain_complete_journey`
- `v2_captain_send_journey_message`

The access-routing tranche prevents users without a linked active captain record from opening `/captain`.
