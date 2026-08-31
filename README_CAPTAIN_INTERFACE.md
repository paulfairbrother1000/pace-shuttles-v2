# Pace Shuttles V2 — Captain Operations Runbook

The Captain Dashboard at `/captain` is the mobile-first workspace for assigned journeys, manifests, private party messaging, journey broadcasts, start/completion records, and incident notes.

This document describes the release candidate. It does not assert that the journey-communications migrations are active in production; preview database and browser verification remain required before activation.

## Access prerequisites

A signed-in user reaches `/captain` only when all of the following are true:

- the account is linked to an active `pace_v2.captains` record;
- the captain belongs to the confirmed allocation's operator;
- the assignment is active for that confirmed allocation;
- the captain is active and eligible for the allocated vehicle type; and
- the allocated vehicle is active.

Operator membership alone does not grant Captain Dashboard or private-message access. Site Admin supervision uses its own interface and does not impersonate a captain.

## Operating a journey

1. Open `/captain`, select the assigned journey, and confirm route, vehicle, scheduled times, and manifest.
2. At T-24, the database opens the direct-message window. Each paid active party leader who contacts the captain, or receives a broadcast, remains in a separate booking thread. Before T-24, customers use Pace Shuttles Support.
3. Reply from the selected party thread when the response is specific to that booking. The other parties cannot see it.
4. Use a broadcast only when every eligible party leader needs the same update. Choose one approved category: late running, pickup change, weather/conditions, safety, or operational.
5. Start the journey from the dashboard so actual departure is recorded.
6. Complete the journey promptly. Record actual arrival, whether completion was normal, captain notes, and any incident summary.
7. Direct messaging stays open until actual completion plus four hours. If completion is missing, the fallback closes it 12 hours after scheduled arrival and raises an operational exception.

## Private reply versus broadcast

| Action | Use for | Database result |
| --- | --- | --- |
| Reply to party | One booking's question or circumstances | One immutable message in that party's private thread |
| Broadcast | A journey-wide operational update | One audited source plus one private copy, in-app notification, and queued email per eligible party leader |

Broadcast replies return privately to the captain; there is no customer group chat. Customer and captain email addresses and telephone numbers are never exposed through journey messaging.

The client supplies one stable request ID for each intentional broadcast. Retrying the same request returns the original source message; changing the allocation or draft requires a new request ID. Do not repeatedly press Send after an uncertain network result—leave the draft in place and retry the same action.

## Completion and incidents

Use **Start journey** at departure and **Complete journey** at arrival. Completion is the authority for the four-hour messaging close and next-local-day feedback schedule.

For abnormal completion or a safety concern:

- set the incident flag;
- write factual voyage notes and a concise incident summary;
- use the safety broadcast only for information every party must receive; and
- escalate through the established Pace Shuttles operations/support process. Do not place personal contact details, payment data, medical details beyond operational need, or speculation in messages.

## What the captain can see

- Assigned journey and allocation details.
- Manifest requirements needed to operate the journey.
- Separate private party-leader threads, sender type, timestamps, and unread state.
- The captain's own private replies and broadcast copies in each party thread.

The captain cannot see another captain's allocation, an unassigned party thread, customer contact details, feedback evidence, quality administration, or service-role email queues.

## Troubleshooting

| Symptom | Check | Action |
| --- | --- | --- |
| Journey missing | Active captain link, assignment, operator, vehicle, and vehicle-type eligibility | Ask Site Admin to correct the authoritative allocation; do not work around it in the browser |
| Messaging closed | T-24/open and actual-completion/fallback close times | Use ordinary Pace Shuttles Support outside the window |
| Broadcast reports a recipient failure | Site Admin operational alerts and broadcast delivery status | In-app copies remain; Site Admin corrects/retries email delivery |
| Completion unavailable | Assignment is still current and journey state permits completion | Escalate immediately so the overdue-completion fallback does not become the operational record |
| Send result uncertain | Original draft and request ID remain visible | Retry the unchanged draft once; do not create a second broadcast |

## Protected interfaces

Reads:

- `v2_captain_my_journeys`
- `v2_captain_my_manifest`
- `v2_captain_my_journey_conversations`
- `v2_captain_my_journey_messages`
- `v2_captain_my_journey_message_windows`

Writes:

- `v2_captain_start_journey`
- `v2_captain_complete_journey`
- `v2_captain_reply_to_party`
- `v2_captain_broadcast_to_parties`
- `v2_mark_journey_conversation_read`

All identity, assignment, recipient, paid/active booking, category, and communication-window decisions are derived again in PostgreSQL. Direct writes to journey message tables are not a supported interface.

## Release verification

Before production activation, use separate preview identities to verify:

- assigned captain access and other-captain/operator denial;
- two customers remain in separate threads;
- one private reply reaches only its party;
- one broadcast produces one private copy and queued email per party;
- actual completion leaves messaging open until +4h and closed at the exact boundary; and
- browser console, function logs, notification records, delivery records, and operational alerts contain no unexplained failures.

The rollback-only database fixtures are `supabase/tests/journey_communications_security_contract.sql` and `supabase/tests/journey_communications_end_to_end.sql`.
