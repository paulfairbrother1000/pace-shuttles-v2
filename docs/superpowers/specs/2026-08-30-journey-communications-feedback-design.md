# Journey Communications and Feedback Design

## Purpose

Build the production Pace Shuttles journey-communications lifecycle covering:

- the T-24 “Your journey is tomorrow” customer email;
- mandatory eligible-captain assignment with every confirmed vehicle allocation;
- secure one-to-one party-leader and captain messaging;
- captain broadcasts to every party leader on a journey;
- Site Admin supervision and operational exceptions;
- the 10:00 a.m. local-time, next-day feedback email and survey; and
- separate, auditable quality measures for Pace Shuttles, operators, captains, pickup locations and destinations.

The implementation must extend the existing V2 notification, support, captain-message, feedback and quality capabilities. It must not create a parallel communications platform or depend on V1.

## Approved business rules

### Allocation prerequisite

A vehicle cannot be confirmed for a journey without an eligible captain. The database must reject allocation confirmation unless:

- the vehicle is active and eligible for the scheduled service;
- the captain is active;
- the captain belongs to the allocated operator;
- the captain is eligible for the vehicle type; and
- the captain is assigned to that confirmed allocation.

The interface must prevent the invalid action, but database enforcement is authoritative.

### Communication window

Direct customer-captain communication opens at T-24 relative to the scheduled departure timestamp. It closes four hours after the recorded actual journey completion timestamp.

Before T-24 and after closure, the customer uses ordinary Pace Shuttles Support. If no actual completion has been recorded, create a Site Admin overdue-completion alert at the scheduled arrival time and close direct captain messaging 12 hours after scheduled arrival. Site Admin can continue the matter through ordinary supervised support, but the absence of completion cannot create indefinite captain access.

### Privacy

Customers and captains communicate only through Pace Shuttles. Neither side receives the other party’s private email address or telephone number. A captain may see the party leader’s name, allocated party and relevant manifest requirements, but not private contact details.

Each booking party has a separate private conversation. Party leaders cannot see other parties or their replies. Messages are immutable; corrections are additional messages.

## T-24 customer email

### Eligibility and timing

At T-24, create one reminder per paid, active party-leader booking when the journey has both a confirmed vehicle and an eligible assigned captain. The scheduler must be timezone-safe and idempotent.

The notification must have a unique template-and-booking key so retries cannot generate a duplicate successful email.

If T-24 arrives without a compliant allocation:

- do not send an incomplete email;
- create an immediate high-priority Site Admin operational alert;
- mark the journey “T-24 details overdue”;
- send the complete email immediately after the allocation becomes compliant; and
- record the late-send delay for operational reporting.

Missing customer email, pickup directions or country timezone also creates an operational exception and prevents malformed email delivery.

### Subject

`Your Journey to <Destination> is Tomorrow!`

### Approved body

> Hi `<First name>`,
>
> The time is almost upon us!
>
> Your journey from `<Pickup>` to `<Destination>` at `<Local journey time>` is scheduled with Captain `<Captain full name>` aboard the `<Vehicle type>` `<Vehicle name>`.
>
> Please arrive at `<Pickup>` no later than `<Local journey time minus 15 minutes>`.
>
> **Get directions to your pickup point**  
> `<Google Maps directions button/link>`
>
> `<Only for a wet destination:>`
>
> **Please prepare for a wet arrival**
>
> There is no mooring at `<Destination>`, so you will get wet when you disembark. Please bring a towel and any suitable clothing or footwear you may require.
>
> **Need to contact your captain on the day of travel?**
>
> Sign in to [My Journeys](https://www.paceshuttles.com/customer), select this booking and open **Help & Support**. Choose **Day of Travel**, write your message and select **Contact captain**.
>
> Your captain will receive the message through Pace Shuttles. This secure conversation will remain available until four hours after your journey is completed.
>
> We hope you have a wonderful journey to `<Destination>` with Captain `<Captain surname>`.
>
> Regards,  
> The Pace Shuttles Team

The pickup Google Maps directions URL is authoritative for the directions button. The wet-arrival section is included only when the destination is classified as wet.

## Journey messaging

### Customer experience

In My Journeys, the customer selects a booking. During the communication window, **Day of Travel** appears as a support category and changes the action to **Contact captain**.

The customer sees:

- their private party-leader/captain thread;
- journey broadcasts copied into that thread;
- delivery time and sender type; and
- a clear closed state after the window ends.

Ordinary Pace Shuttles Support remains available throughout and is the only available route outside the captain window.

### Captain experience

The existing simple, mobile-first Captain Dashboard remains the operational interface. It gains:

- unread-message and operational-alert badges against assigned journeys;
- party-leader conversations listed separately;
- **Reply to party** for one-to-one replies;
- **Message all parties** for journey-wide announcements;
- the messaging-window state and closing time; and
- categories for late running, pickup change, weather/conditions, safety and general operational updates.

The existing assigned-journey, manifest, start-journey and complete-journey functions remain prominent.

### Broadcast semantics

A captain broadcast creates one immutable, audited source message and one delivery record per eligible party-leader booking. Each delivery:

- appears in the recipient’s private conversation;
- creates an in-app notification; and
- queues an email to that party leader.

Replies to a broadcast are private replies to the captain. They never create a customer group chat.

Email failure must not remove the in-app message. Failures are recorded and surfaced to Site Admin for retry or intervention.

### Site Admin supervision

Site Admin can:

- view all journey conversations and broadcasts;
- see unread and delivery states;
- reply or intervene as Pace Shuttles;
- review immutable audit history; and
- see conversations approaching or beyond operational time limits.

Operator users do not automatically receive access to private customer conversations.

## Feedback email and survey

### Timing and eligibility

At 10:00 a.m. in the journey country’s local timezone on the calendar day following actual completion, queue one feedback email per eligible completed, paid party-leader booking.

The email links to the completed booking in authenticated My Journeys. Only the booking owner may submit, and only one response is accepted per booking. The queue must be idempotent and retry-safe.

### Subject

`Thank you for travelling with Pace Shuttles – one more thing…`

### Approved body

> Hi `<First name>`,
>
> Thank you for travelling with Pace Shuttles. We hope you had a wonderful journey in `<Country name>`, travelling from `<Pickup>` to `<Destination>`.
>
> We’d really appreciate your feedback about what went well and what we could improve. Your response will help Pace Shuttles, your operator, captain, pickup location and destination continue improving the experience provided to customers.
>
> **Share your feedback**  
> `<Secure My Journeys feedback link/button>`
>
> The survey should take no more than two minutes.
>
> Thank you again for choosing Pace Shuttles.
>
> Regards,  
> The Pace Shuttles Team

### Survey fields

The survey records:

1. **Booking experience:** “How would you rate your Pace Shuttles booking experience?” — required 1–5 stars.
2. **Pace Shuttles NPS:** “How likely are you to recommend Pace Shuttles to a friend?” — required 0–10.
3. **Operator and journey:** required 1–5 stars.
4. **Captain:** required 1–5 stars.
5. **Pickup location:** required 1–5 stars.
6. **Destination:** required 1–5 stars.
7. **What went particularly well?** — optional text.
8. **What could we improve?** — optional text.
9. **Testimonial permission:** optional, explicit consent covering the submitted “went well” and “improve” comments; false by default.

The interface must explain the NPS endpoints and remain practical on a mobile phone.

## Quality treatment

### Pace Shuttles measures

The NPS response is a platform-level Pace Shuttles measure:

- 0–6: detractor;
- 7–8: passive; and
- 9–10: promoter.

It does not automatically affect the operator’s quality score.

Booking-experience ratings create a separate Pace Shuttles measure with average, response count, trend, comments and low-score alerts.

### Operator and captain measures

Operator/journey and captain ratings contribute to the operator’s decaying quality score with configurable initial weighting:

- 60% operator/journey rating; and
- 40% captain rating.

Captain ratings also create a separate captain performance history. Evidence remains linked to the booking, journey, allocation, operator, vehicle and captain.

Site Admin can review attribution and redirect or exclude evidence caused by Pace Shuttles, the customer, weather or another external factor. Any 1-star or 2-star rating creates a review alert and supporting evidence; it must not become an unexplained silent score change.

### Location measures

Pickup and destination ratings create separate location-quality histories. They never automatically affect the operator quality score.

For each pickup and destination, Site Admin can see:

- average rating and response count;
- trend over time;
- recent comments;
- poor-rating alerts;
- comparison with locations in the same country; and
- the journey evidence behind every score.

## Data model boundaries

Extend existing V2 structures rather than duplicating them:

- customer feedback gains booking-experience, captain, pickup and destination ratings, separate positive/improvement comments and testimonial consent;
- journey conversations link to one booking and one confirmed allocation;
- broadcasts retain a source record and per-booking delivery records;
- notification records retain template, booking, departure, email delivery and provider identifiers;
- quality evidence identifies its target dimension and retains source attribution; and
- operational alerts retain exception type, journey, detection time, resolution time and lateness.

The schema must support reporting without parsing email bodies or message text.

## Authorization and security

All exposed records require RLS or protected, narrowly granted RPCs.

- Anonymous users cannot read manifests, conversations, feedback, quality evidence or email queues.
- A customer may access only bookings owned by their authenticated user ID.
- A captain may access only journeys and allocations actively assigned to their captain record.
- Customer and captain message RPCs enforce the communication window in the database.
- Broadcast RPCs validate the assigned captain once and derive recipients server-side.
- Site Admin checks use the existing authoritative Site Admin function.
- Operator membership alone does not grant private-message access.
- Service-role email dispatch never exposes its credential to the browser.
- New security-definer functions revoke default PUBLIC and anonymous execution, explicitly validate `auth.uid()`, and receive only the minimum required grants.
- Views exposed through the Data API use security-invoker behaviour where supported or equivalent protected RPC access.

## Scheduling and delivery

The existing scheduled operations endpoint and customer-email dispatcher remain the delivery path.

Scheduling must:

- calculate T-24 from the scheduled departure timestamp;
- calculate feedback due time as 10:00 a.m. in the country timezone on the next local calendar day after actual completion;
- claim queue rows atomically;
- tolerate retries and concurrent runs;
- prevent duplicate successful delivery;
- preserve in-app notifications when email fails; and
- record provider IDs and failure reasons.

## Site Admin reporting

Site Admin gains:

- T-24 allocation exceptions and late-send duration;
- email queue and delivery failures;
- supervised journey conversations and broadcast delivery status;
- feedback requiring attribution review;
- Pace Shuttles NPS and booking-experience dashboards;
- operator quality and evidence;
- captain performance;
- pickup performance; and
- destination performance.

## Acceptance criteria

### Allocation

- Confirming a vehicle allocation without an eligible assigned captain fails in both UI validation and the database.
- A compliant vehicle-and-captain allocation succeeds and is visible to the captain.

### T-24 email

- Exactly one reminder is generated per eligible booking.
- Times are rendered in the journey country timezone.
- The arrival time is scheduled departure minus 15 minutes.
- The pickup directions link is present and valid.
- Wet destinations include the wet-arrival wording; dry destinations omit it.
- Missing allocation or required content creates an operational exception and withholds malformed email.
- Completing a late allocation sends the reminder immediately and records lateness.

### Messaging

- A party leader cannot read another party’s messages.
- The assigned captain can reply to a single party.
- A captain broadcast reaches every eligible party leader through an audited private-thread copy, in-app notification and email queue.
- A party reply to a broadcast remains private.
- Messaging is rejected before T-24 and more than four hours after actual completion. If completion is missing, it is rejected 12 hours after scheduled arrival and an overdue-completion alert exists.
- Site Admin can supervise and intervene.
- Operator-only and anonymous users are denied access.

### Feedback

- Feedback queues at 10:00 a.m. local time on the next calendar day after actual completion.
- Exactly one request and response are allowed per booking.
- All approved survey fields are stored and displayed.
- NPS and booking experience affect only Pace Shuttles measures.
- Operator and captain ratings affect operator quality at the configurable 60/40 weighting after attribution.
- Captain ratings remain separately reportable.
- Pickup and destination ratings remain separately reportable and do not affect the operator score.
- Testimonial use requires explicit recorded consent.

### Verification

- Database behaviour tests cover timezone boundaries, idempotency, eligibility and message windows.
- RLS/RPC tests cover customer, captain, operator, anonymous and Site Admin identities.
- Component tests cover captain, customer, feedback and Site Admin states on desktop and mobile.
- Email rendering tests cover all conditional content and escaping.
- The full automated suite and optimized production build pass.
- Preview deployment receives end-to-end role verification before production activation.

## Out of scope

- Exposing customer or captain personal contact information.
- Customer group chat.
- Operator access to private conversations solely through operator membership.
- Anonymous feedback submission.
- V1 database or application dependencies.
- Changing the established allocation timing model beyond enforcing the mandatory captain prerequisite.

