\set ON_ERROR_STOP on

-- Release-gate rehearsal for the complete paid return-journey lifecycle.
-- Each included pgTAP fixture owns a transaction and rolls it back, allowing
-- this file to run safely against a seeded Supabase preview database.
--
-- Stage 1 creates paid whole-party demand, provisional captain reservations,
-- competing overlapping services, T-72 holds/removal, T-24 confirmation and
-- assignment, terminal release, plus the legacy conflicting-assignment
-- backfill case. It asserts captain identity at every reservation transition.
\echo '1/4 captain reservations: order, allocation, T-72, T-24 and backfill'
\ir captain_resource_reservations_behavior.sql

-- Stage 2 proves the confirmed itinerary/customer and operator communication
-- records are queued once with the assigned vehicle and captain evidence.
\echo '2/4 T-24 operator and customer communications'
\ir t24_journey_notifications_behavior.sql

-- Stage 3 creates an explicit paired return duty and exercises the same public
-- captain interfaces used on journey day: Leg 1 start/end, Leg 2 start/end,
-- shared completion and settlement. Its fixture also proves that feedback is
-- not released before the final leg/final allocation has completed.
\echo '3/4 paired return journey-day lifecycle'
\ir captain_duties_and_return_legs_contract.sql

-- Stage 4 advances the completed journey to the next local feedback window,
-- queues exactly one post-journey message and submits attributed feedback.
\echo '4/4 post-journey feedback scheduling and submission'
\ir journey_feedback_quality_behavior.sql

\echo 'Captain reservation lifecycle rehearsal passed'
