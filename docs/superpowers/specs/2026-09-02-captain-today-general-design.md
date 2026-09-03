# Captain Today and General workspace design

## Objective

Restructure the captain workspace around a safety-critical, mobile-first Today screen. A captain working on a boat must be able to review the manifest, record each leg's actual start and end, and communicate with passengers quickly. Planning, history and general information must not compete with those immediate actions.

## Navigation

The captain workspace has two persistent top-level tabs:

- **Today** is the default. It contains only duties operating today, their manifest, leg controls and communications.
- **General** contains possible journeys, confirmed future journeys, completed journeys/history, operating guidance and the other non-immediate information already available to captains.

The selected tab is represented in the URL so refresh and browser navigation preserve it. The layout is designed for a narrow mobile viewport first and expands without changing the workflow on larger screens.

## Journey design and automatic pairing

Site Admin configures a return journey as part of the scheduled journey design. The design captures:

- outbound pickup and destination;
- outbound scheduled departure and expected arrival;
- return scheduled departure and expected arrival or duration;
- applicable operating dates or recurrence;
- vehicle type and the existing route, allocation and commercial rules.

Publishing the design creates or updates two ordinary scheduled departures:

1. Leg 1 travels from the configured pickup to the destination.
2. Leg 2 travels from the destination back to the pickup.

The system links both departures with one immutable journey-pair identifier and explicit leg order. Pairing is created from the admin design; it is never inferred from similar routes, times, captains or vehicles. Existing one-way journey designs remain valid and appear as single-leg duties.

The paired departures share the same operator, vehicle, captain assignment, booking parties and manifest. A booking on the paired design covers the complete outbound-and-return duty. Existing allocation and capacity rules continue to determine the assigned operator and vehicle without duplication.

## Today selection

"Today" is calculated using the operating country's configured timezone, not the captain's device timezone. The active duty is selected first; otherwise the next scheduled duty is selected. If the captain has more than one duty today, the active or next duty is shown in full and the others appear in a compact duty selector.

Completed duties remain available in today's selector until the local day ends. Future and historical duties belong on General.

## Today header

The selected duty header shows:

- journey title;
- local date;
- first pickup time and place;
- vehicle name;
- operator name;
- overall duty state: Ready, Leg 1 active, At destination, Leg 2 active, Completed or Incident.

The header avoids KPI cards and planning information.

## Manifest

The manifest initially shows one row per booking party, not one row per passenger. Each row shows:

- lead passenger name;
- party composition, for example `3 adults, 2 children, 1 infant`;
- payment status, prominently including `Paid`;
- relevant accessibility or special-requirement indicator;
- unread private-message count when present.

Opening a party reveals every passenger's name and category (adult, child or infant), together with relevant operational special requirements. The same manifest applies to both legs.

The captain may open the party's protected conversation directly from the expanded party. Customer contact details that are not operationally required remain hidden.

## Leg controls

Each leg has its own section showing route, scheduled departure, expected arrival, state and recorded actual timestamps.

### Valid action sequence

Actions are strictly sequential:

1. Start Leg 1
2. End Leg 1
3. Start Leg 2
4. End Leg 2

Only the next valid action is enabled. Leg 2 cannot start before Leg 1 has ended. Repeated submissions are idempotent and cannot overwrite an already recorded timestamp. The server, not the device, records the authoritative timestamp.

Start uses a short confirmation naming the leg and explaining that the actual departure time will be recorded. End opens a compact completion panel with **Normal completion** selected by default and **Incident** as the alternative. Selecting Incident requires a summary. Optional journey notes may be added without blocking a normal completion. A final confirmation records the actual arrival time.

While an action is being saved, all conflicting controls are disabled. Success shows the recorded local time beside the relevant action. Failure keeps the action available, preserves entered incident/notes content, and displays a clear error without advancing the leg state.

The controls use large touch targets, high contrast, plain labels and sufficient spacing to minimise accidental operation on a moving boat.

## Communications

The Today communications section provides two clear entry points:

- **Message a party** opens the selected party's private conversation.
- **Message all** opens the journey-wide broadcast composer.

Existing protected messaging windows, categories, idempotency, unread state, audit history and customer delivery behaviour are retained. Drafts remain scoped to the selected duty and party. Switching duties cannot send or display a stale draft from another duty.

## General tab

General contains:

- possible journeys;
- confirmed future journeys;
- completed journey history;
- existing non-today captain information and operating guidance.

General does not expose Start or End controls for a duty that is not operating today. A confirmed journey due today links back to its Today duty rather than duplicating operational controls.

## Data model

The change is additive:

- add a journey-pair/duty record or equivalent stable pairing identity;
- link each paired departure to that identity with a constrained leg number of 1 or 2;
- store independent actual departure and arrival timestamps per departure/leg using the existing journey timing fields;
- store completion classification, notes and incident evidence per leg;
- expose a protected captain Today projection grouped by duty;
- extend the protected manifest projection with lead-passenger, party-composition and payment-state fields;
- add protected, idempotent captain leg start/end functions that validate identity, assignment, local operating date and action order.

Database policies must continue to prevent a captain from reading or changing another captain's duties, manifests, messages or timestamps. Site Admin journey-design functions create and maintain the paired departures atomically.

## Compatibility and migration

Existing one-way departures remain single-leg duties. Existing completed and in-progress journeys retain their timestamps and history. No existing booking, allocation, communication, settlement or quality record is rewritten.

The admin journey editor may save an existing design without a return leg. Adding a return leg creates and links the reverse departure. Removing a return leg is permitted only when neither linked departure has bookings, allocation evidence or recorded operation; otherwise the editor explains why it cannot be removed.

Live database migration and production activation require explicit approval after preview verification.

## Quality and audit evidence

Each leg produces independent evidence for:

- scheduled versus actual departure;
- scheduled versus actual arrival;
- departure and arrival delay;
- normal or incident completion;
- captain, vehicle and operator identity;
- action actor and server timestamp.

The duty becomes Completed only after its final configured leg ends. Settlement and post-journey feedback continue after the complete duty, not after Leg 1. Existing quality calculations remain unchanged until a separately approved change consumes the new leg-level measures.

## Verification

Automated verification must cover:

- admin creation and atomic pairing of outbound and return departures;
- one-way journey compatibility;
- journey-local Today filtering around midnight and timezone boundaries;
- active/next duty selection and multiple-duty switching;
- grouped manifest composition, payment state and passenger drill-down;
- captain isolation and denial of cross-captain access;
- the four-step leg action sequence, idempotency and invalid-order rejection;
- normal and incident completion flows, including preserved drafts after failure;
- private-party and broadcast communications without stale duty context;
- General tab separation and absence of future Start/End controls;
- mobile layout, touch-target size and disabled/busy/success/error states;
- regression coverage for existing allocation, booking, settlement, feedback and messaging behaviour;
- complete test suite, production build, preview-database scenario and browser verification before activation.

Production deployment must stop before live database activation unless the user explicitly approves the migration and release.
