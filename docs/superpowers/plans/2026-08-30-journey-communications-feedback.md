# Journey Communications and Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the T-24 journey reminder, mandatory captain allocation, secure party-leader/captain messaging and broadcasts, and next-day feedback with separated platform, operator, captain, pickup and destination quality measures.

**Architecture:** Extend the existing V2 allocation, notification, support, captain-message, feedback and quality records. PostgreSQL/RPCs are the authorization and timing authority; Next.js renders the role-specific interfaces; the existing scheduled operations endpoint claims idempotent notification work and Resend delivers email.

**Tech Stack:** Next.js 15 App Router, React, TypeScript, Supabase/PostgreSQL, RLS/protected RPCs, Resend, Node test runner, Vitest/Testing Library, Vercel.

**Spec:** `docs/superpowers/specs/2026-08-30-journey-communications-feedback-design.md`

## Global Constraints

- Pace Shuttles V2 only; no V1 database or application dependency.
- A confirmed vehicle allocation must include an active, eligible captain belonging to the allocated operator.
- Direct captain messaging opens at T-24 and closes four hours after actual completion, or 12 hours after scheduled arrival when completion is missing.
- Customer and captain email addresses and telephone numbers must not be exposed to one another.
- Every party conversation is private; captain broadcasts fan out into private threads and never create customer group chat.
- T-24 reminders and feedback requests are idempotent per booking and template.
- Feedback is due at 10:00 a.m. in the journey country timezone on the next local calendar day after actual completion.
- Pace Shuttles NPS and booking experience do not change operator quality.
- Operator quality uses configurable initial weighting of 60% operator/journey rating and 40% captain rating.
- Pickup and destination ratings remain separate from operator quality.
- Testimonial consent is false by default and must be explicit.
- All new exposed data is protected with ownership/assignment-aware RLS or narrowly granted RPCs; never expose a service-role key to the browser.
- Database migrations must be created with `supabase migration new <name>` at execution time, not by inventing timestamps.
- Production activation occurs only after database, application, preview and live role verification pass.

---

### Task 1: Allocation and communications data foundation

**Files:**
- Create via `supabase migration new journey_communications_foundation`: the resulting migration file ending `_journey_communications_foundation.sql`
- Create: `supabase/tests/journey_communications_foundation_contract.sql`
- Create: `supabase/tests/journey_communications_foundation_behavior.sql`
- Modify: `tests/service-specific-offers.test.mjs`

**Interfaces:**
- Consumes: existing `pace_v2.confirmed_allocations`, `captain_assignments`, `bookings`, `orders`, `departures`, `routes`, `captains`, `captain_vehicle_types`, `support_conversations`, `support_messages`, `customer_notifications`.
- Produces: `pace_v2.journey_conversations`, `pace_v2.journey_messages`, `pace_v2.journey_broadcast_deliveries`, `pace_v2.operational_alerts`; allocation captain constraint/trigger; helper functions `pace_v2.journey_message_opens_at(uuid)`, `pace_v2.journey_message_closes_at(uuid)` and `pace_v2.is_journey_message_window_open(uuid,timestamptz)`.

- [ ] **Step 1: Create the migration through the installed CLI**

Run:

```bash
supabase --version
supabase migration new journey_communications_foundation
```

Expected: one new migration ending `_journey_communications_foundation.sql`.

- [ ] **Step 2: Write failing contract and behavior tests**

Create contract assertions for all tables, keys, unique constraints and protected helper functions. The behavioral test must prove invalid allocation rejection and the exact messaging windows:

```sql
begin;

do $$ begin
  if not exists (
    select 1 from information_schema.tables
    where table_schema='pace_v2' and table_name='journey_conversations'
  ) then raise exception 'journey conversations missing'; end if;

  if not exists (
    select 1 from pg_constraint
    where conname='journey_conversations_booking_allocation_key'
  ) then raise exception 'one private thread per booking/allocation is not enforced'; end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='pace_v2' and p.proname='is_journey_message_window_open'
  ) then raise exception 'message window helper missing'; end if;
end $$;

rollback;
```

Add a Node contract assertion that the current allocation migration chain contains an explicit captain eligibility check, not only UI validation.

- [ ] **Step 3: Run the new tests and verify RED**

Run:

```bash
node --test tests/service-specific-offers.test.mjs
```

Run the two SQL files against a disposable/local database. Expected: failure because the new structures and captain constraint do not exist.

- [ ] **Step 4: Implement the foundation migration**

Use UUID primary keys, immutable message rows and explicit foreign keys. Required shapes:

```sql
create table pace_v2.journey_conversations(
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references pace_v2.bookings(id),
  confirmed_allocation_id uuid not null references pace_v2.confirmed_allocations(id),
  status text not null default 'scheduled' check(status in('scheduled','open','closed')),
  opened_at timestamptz,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  unique(booking_id,confirmed_allocation_id)
);

create table pace_v2.journey_messages(
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references pace_v2.journey_conversations(id),
  sender_type text not null check(sender_type in('customer','captain','site_admin','captain_broadcast')),
  sender_user_id uuid references auth.users(id),
  category text not null check(category in('day_of_travel','late_running','pickup_change','weather','safety','operational')),
  message_text text not null check(length(trim(message_text)) between 1 and 4000),
  broadcast_source_id uuid references pace_v2.journey_messages(id),
  created_at timestamptz not null default now()
);
```

Create `journey_broadcast_deliveries` with unique `(broadcast_message_id,booking_id)`, and `operational_alerts` with unique active exception keys. Enable RLS on every new table and revoke direct anonymous access.

Implement the window close calculation as actual completion + four hours, otherwise scheduled arrival + 12 hours. Add a deferred constraint trigger to the allocation-confirmation path that verifies active captain/operator/vehicle-type eligibility before commit.

- [ ] **Step 5: Verify GREEN and run database advisors**

Run contract and behavior SQL, then:

```bash
supabase db advisors
supabase migration list --local
node --test tests/service-specific-offers.test.mjs
```

Expected: all pass; no exposed-table or security-definer warnings introduced.

- [ ] **Step 6: Commit Task 1**

```bash
git add supabase/migrations supabase/tests/journey_communications_foundation_contract.sql supabase/tests/journey_communications_foundation_behavior.sql tests/service-specific-offers.test.mjs
git commit -m "feat: enforce captain-backed journey communications"
```

---

### Task 2: T-24 scheduling, operational exceptions and email rendering

**Files:**
- Create via `supabase migration new t24_journey_notifications`: the resulting migration file ending `_t24_journey_notifications.sql`
- Create: `lib/journey-email-content.ts`
- Create: `tests/journey-email-content.test.mjs`
- Create: `tests/journey-notification-contract.test.mjs`
- Create: `supabase/tests/t24_journey_notifications_behavior.sql`
- Modify: `lib/customer-email.ts`
- Modify: `app/api/operations/run-scheduled/route.ts`

**Interfaces:**
- Consumes: Task 1 allocation guarantees, existing `customer_notifications`, pickup `directions_url`, destination `wet_or_dry`, country timezone and Resend dispatcher.
- Produces: `public.v2_system_schedule_t24_journey_notifications(p_as_of timestamptz)` and pure `buildTomorrowJourneyEmail(input): {subject:string; text:string}`.

- [ ] **Step 1: Create the migration through the CLI**

```bash
supabase migration new t24_journey_notifications
```

- [ ] **Step 2: Write failing rendering tests**

Test the exact approved copy, 15-minute subtraction, local time, directions link and conditional wet section:

```js
test('wet destination reminder includes allocation, directions and wet-arrival advice',()=>{
  const email=buildTomorrowJourneyEmail({
    firstName:'Paul',countryName:'British Virgin Islands',pickupName:'Nanny Cay Marina',
    destinationName:'The Soggy Dollar',departureLocalLabel:'12:00 PM',arrivalByLocalLabel:'11:45 AM',
    captainFullName:'James Williams',captainSurname:'Williams',vehicleType:'Speed Boat',
    vehicleName:'Sea Runner',pickupDirectionsUrl:'https://maps.app.goo.gl/example',wetDestination:true
  });
  assert.equal(email.subject,'Your Journey to The Soggy Dollar is Tomorrow!');
  assert.match(email.text,/Captain James Williams aboard the Speed Boat Sea Runner/);
  assert.match(email.text,/no later than 11:45 AM/);
  assert.match(email.text,/Please prepare for a wet arrival/);
  assert.match(email.text,/Contact captain/);
});
```

Add the dry variant asserting the wet paragraph is absent and an escaping test for customer-provided names.

- [ ] **Step 3: Write failing database behavior tests**

Cover one notification per booking/template, T-24 eligibility, late allocation, `t24_details_overdue`, missing directions/timezone/email exceptions and no malformed queue rows.

- [ ] **Step 4: Run focused tests and verify RED**

```bash
node --test tests/journey-email-content.test.mjs tests/journey-notification-contract.test.mjs
```

Expected: imports/functions are missing. SQL behavior expected to fail before migration.

- [ ] **Step 5: Implement pure email content**

Define:

```ts
export type TomorrowJourneyEmailInput={
 firstName:string;countryName:string;pickupName:string;destinationName:string;
 departureLocalLabel:string;arrivalByLocalLabel:string;captainFullName:string;
 captainSurname:string;vehicleType:string;vehicleName:string;
 pickupDirectionsUrl:string;wetDestination:boolean;
};

export function buildTomorrowJourneyEmail(input:TomorrowJourneyEmailInput):{subject:string;text:string};
```

Generate exactly the approved subject/body from the spec. Keep URL creation outside HTML rendering; `renderCustomerEmailHtml` remains responsible for safe HTML escaping/linking.

- [ ] **Step 6: Implement idempotent scheduler and exception recovery**

The protected scheduler must derive all recipients server-side, insert with a unique key equivalent to `(booking_id,'journey_tomorrow')`, and create/upsert operational alerts for incomplete data. When allocation later becomes compliant, resolve the alert, queue immediately and record `minutes_late` in notification metadata.

Update the scheduled endpoint sequence:

```ts
await supabase.rpc('v2_system_schedule_t24_journey_notifications',{p_as_of:new Date().toISOString()});
const emailResult=await dispatchDueCustomerEmails(25);
```

Do not trust caller-supplied recipient, vehicle, captain or route data.

- [ ] **Step 7: Verify Task 2**

Run the focused Node/SQL tests, full Node tests touching the scheduler and:

```bash
npm test
npm run build
```

Expected: approved email variants pass; no duplicate queue rows; build succeeds.

- [ ] **Step 8: Commit Task 2**

```bash
git add supabase/migrations supabase/tests/t24_journey_notifications_behavior.sql lib/journey-email-content.ts lib/customer-email.ts app/api/operations/run-scheduled/route.ts tests/journey-email-content.test.mjs tests/journey-notification-contract.test.mjs
git commit -m "feat: send complete T-24 journey reminders"
```

---

### Task 3: Private party-leader and captain messaging RPCs

**Files:**
- Create via `supabase migration new private_journey_messaging`: the resulting migration file ending `_private_journey_messaging.sql`
- Create: `supabase/tests/private_journey_messaging_contract.sql`
- Create: `supabase/tests/private_journey_messaging_behavior.sql`
- Modify: `lib/data.ts`
- Create: `tests/journey-messaging-api.test.mjs`

**Interfaces:**
- Consumes: Task 1 tables/window helpers and existing authenticated access context.
- Produces: `v2_customer_open_captain_conversation`, `v2_customer_send_captain_message`, `v2_captain_reply_to_party`, `v2_site_admin_reply_journey_conversation`; protected views `v2_customer_my_journey_conversations`, `v2_customer_my_journey_messages`, `v2_captain_my_journey_conversations`, `v2_captain_my_journey_messages`.

- [ ] **Step 1: Create migration and failing authorization tests**

```bash
supabase migration new private_journey_messaging
```

Behavior fixtures must include two bookings on one allocation, their two owners, the assigned captain, another captain, an operator-only user, Site Admin and anonymous role. Assert:

```sql
-- owner A sees A thread, never owner B thread
-- assigned captain sees both separate threads
-- other captain/operator/anon see neither
-- Site Admin sees both
-- sends fail before T-24 and after the close boundary
```

- [ ] **Step 2: Run SQL tests and verify RED**

Expected: functions/views missing.

- [ ] **Step 3: Implement protected views and RPCs**

Every write RPC must obtain `auth.uid()` internally, derive the booking/allocation/captain and call `is_journey_message_window_open`. Grant customer calls to `authenticated`, but rely on ownership predicates—not `TO authenticated` alone.

Required client wrappers:

```ts
export const customerOpenCaptainConversation=(bookingId:string,message:string)=>
 rpc('v2_customer_open_captain_conversation',{p_booking_id:bookingId,p_message_text:message});
export const customerSendCaptainMessage=(conversationId:string,message:string)=>
 rpc('v2_customer_send_captain_message',{p_conversation_id:conversationId,p_message_text:message});
export const captainReplyToParty=(conversationId:string,message:string,category:string)=>
 rpc('v2_captain_reply_to_party',{p_conversation_id:conversationId,p_message_text:message,p_category:category});
```

Keep ordinary support RPCs unchanged.

- [ ] **Step 4: Verify privacy and API contracts GREEN**

Run both SQL files and:

```bash
node --test tests/journey-messaging-api.test.mjs
```

- [ ] **Step 5: Commit Task 3**

```bash
git add supabase/migrations supabase/tests/private_journey_messaging_contract.sql supabase/tests/private_journey_messaging_behavior.sql lib/data.ts tests/journey-messaging-api.test.mjs
git commit -m "feat: add private customer captain messaging"
```

---

### Task 4: Captain broadcasts and delivery fan-out

**Files:**
- Create via `supabase migration new captain_journey_broadcasts`: the resulting migration file ending `_captain_journey_broadcasts.sql`
- Create: `supabase/tests/captain_journey_broadcasts_behavior.sql`
- Create: `lib/journey-broadcast-email.ts`
- Create: `tests/journey-broadcasts.test.mjs`
- Modify: `lib/data.ts`
- Modify: `lib/customer-email.ts`

**Interfaces:**
- Consumes: Task 3 private conversations and existing notification dispatcher.
- Produces: `v2_captain_broadcast_to_parties(p_confirmed_allocation_id,p_message_text,p_category)` and per-party conversation/in-app/email deliveries.

- [ ] **Step 1: Create migration and failing fan-out tests**

```bash
supabase migration new captain_journey_broadcasts
```

Test one allocation with three paid active bookings plus cancelled and unpaid bookings. Assert exactly three deliveries and no customer cross-thread visibility.

- [ ] **Step 2: Write failing content/API tests**

```js
test('captain broadcast email identifies route and update category',()=>{
  const email=buildJourneyBroadcastEmail({
    pickupName:'Nanny Cay Marina',destinationName:'The Soggy Dollar',
    captainName:'James Williams',category:'late_running',message:'We are running 15 minutes late.'
  });
  assert.match(email.subject,/Journey update/);
  assert.match(email.text,/running 15 minutes late/);
  assert.match(email.text,/My Journeys/);
});
```

- [ ] **Step 3: Implement atomic server-side fan-out**

The RPC verifies the assigned captain and open window, inserts one broadcast source, derives eligible bookings server-side, creates/fetches one private conversation per booking, inserts private copies, delivery rows and customer notifications in one transaction. A unique delivery key makes retries safe.

Add:

```ts
export const captainBroadcastToParties=(allocationId:string,message:string,category:string)=>
 rpc('v2_captain_broadcast_to_parties',{p_confirmed_allocation_id:allocationId,p_message_text:message,p_category:category});
```

- [ ] **Step 4: Verify fan-out and delivery failure behavior**

Run SQL/Node tests. Simulate Resend failure and assert in-app messages remain while notification status becomes failed/retryable.

- [ ] **Step 5: Commit Task 4**

```bash
git add supabase/migrations supabase/tests/captain_journey_broadcasts_behavior.sql lib/journey-broadcast-email.ts lib/customer-email.ts lib/data.ts tests/journey-broadcasts.test.mjs
git commit -m "feat: broadcast captain updates to party leaders"
```

---

### Task 5: Customer and Captain Dashboard interfaces

**Files:**
- Create: `components/journey-conversation.tsx`
- Create: `components/journey-conversation.test.tsx`
- Modify: `components/captain-dashboard.tsx`
- Modify: `components/pages.tsx`
- Modify: `app/customer-light.css`
- Modify: `app/globals.css`
- Create: `tests/journey-messaging-ui.test.mjs`

**Interfaces:**
- Consumes: Tasks 3–4 protected views/client wrappers.
- Produces: reusable `JourneyConversation` component; customer **Day of Travel / Contact captain** flow; captain private reply/broadcast UI.

- [ ] **Step 1: Write failing component tests**

Cover:

```tsx
render(<JourneyConversation mode="customer" windowState="open" messages={messages} onSend={onSend}/>);
expect(screen.getByRole('button',{name:'Contact captain'})).toBeTruthy();

render(<JourneyConversation mode="captain" windowState="closed" messages={messages} onSend={onSend}/>);
expect(screen.getByText(/conversation closed/i)).toBeTruthy();
expect(screen.queryByRole('button',{name:'Reply to party'})).toBeNull();
```

Add source/contract tests for **Message all parties**, unread badges, categories and no contact-detail rendering.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
npx vitest run components/journey-conversation.test.tsx
node --test tests/journey-messaging-ui.test.mjs
```

- [ ] **Step 3: Implement the reusable thread**

Props must be explicit:

```ts
type JourneyMessage={id:string;sender_type:string;message_text:string;category:string;created_at:string};
type JourneyConversationProps={
 mode:'customer'|'captain'|'site_admin';windowState:'scheduled'|'open'|'closed';
 closesAt?:string|null;messages:JourneyMessage[];busy?:boolean;
 onSend:(message:string,category:string)=>Promise<void>;
};
```

Do not display raw email or phone fields.

- [ ] **Step 4: Wire My Journeys**

Add **Day of Travel** only when the selected booking view reports an open captain window. Keep ordinary support categories and actions. Show broadcasts within the private thread and explain closure/fallback support.

- [ ] **Step 5: Wire Captain Dashboard**

List separate party threads, unread counts and window status. Provide **Reply to party** and **Message all parties** with the approved categories. Retain journey, manifest, start and complete controls.

- [ ] **Step 6: Verify mobile and role states**

Run focused tests, then `npm test` and `npm run build`. Start a local preview and verify narrow/mobile layout with the browser verification skill.

- [ ] **Step 7: Commit Task 5**

```bash
git add components/journey-conversation.tsx components/journey-conversation.test.tsx components/captain-dashboard.tsx components/pages.tsx app/customer-light.css app/globals.css tests/journey-messaging-ui.test.mjs
git commit -m "feat: add customer captain conversation interfaces"
```

---

### Task 6: Feedback schema, scheduling and separated quality calculations

**Files:**
- Create via `supabase migration new journey_feedback_quality`: the resulting migration file ending `_journey_feedback_quality.sql`
- Create: `supabase/tests/journey_feedback_quality_contract.sql`
- Create: `supabase/tests/journey_feedback_quality_behavior.sql`
- Create: `lib/feedback-email-content.ts`
- Create: `tests/feedback-email-content.test.mjs`
- Modify: `lib/data.ts`
- Modify: `app/api/operations/run-scheduled/route.ts`

**Interfaces:**
- Consumes: actual completion timestamps, country timezone, booking ownership, confirmed allocation/captain/pickup/destination and existing quality decay configuration.
- Produces: expanded `customer_feedback`; `captain_quality_history`, `pickup_quality_history`, `destination_quality_history`, platform metrics; `v2_system_schedule_feedback_requests`; revised `v2_customer_submit_feedback`.

- [ ] **Step 1: Create migration and failing schema/behavior tests**

```bash
supabase migration new journey_feedback_quality
```

Assert required 1–5/0–10 checks, false-default testimonial consent, one response per booking, target IDs captured from allocation/route, 10:00 local scheduling and score separation.

- [ ] **Step 2: Write failing email tests**

```js
test('feedback email uses approved thanks and country route copy',()=>{
  const email=buildFeedbackEmail({firstName:'Paul',countryName:'British Virgin Islands',pickupName:'Nanny Cay Marina',destinationName:'The Soggy Dollar',feedbackUrl:'https://www.paceshuttles.com/customer?booking=b1&feedback=1'});
  assert.equal(email.subject,'Thank you for travelling with Pace Shuttles – one more thing…');
  assert.match(email.text,/wonderful journey in British Virgin Islands/);
  assert.match(email.text,/what went well and what we could improve/);
  assert.match(email.text,/no more than two minutes/);
});
```

- [ ] **Step 3: Implement expanded feedback and submission RPC**

Use this client contract:

```ts
export type JourneyFeedbackInput={
 bookingExperienceRating:number;nps:number;operatorRating:number;captainRating:number;
 pickupRating:number;destinationRating:number;wentWell:string;couldImprove:string;
 testimonialConsent:boolean;
};
export const customerSubmitJourneyFeedback=(bookingId:string,input:JourneyFeedbackInput)=>
 rpc('v2_customer_submit_feedback',{p_booking_id:bookingId,p_booking_experience_rating:input.bookingExperienceRating,p_nps:input.nps,p_operator_rating:input.operatorRating,p_captain_rating:input.captainRating,p_pickup_rating:input.pickupRating,p_destination_rating:input.destinationRating,p_went_well:input.wentWell,p_could_improve:input.couldImprove,p_testimonial_consent:input.testimonialConsent});
```

The database derives operator, vehicle, captain, pickup and destination. The customer cannot submit attribution or target IDs.

- [ ] **Step 4: Implement scoring separation**

Create platform evidence for NPS and booking experience with zero operator score effect. Create operator evidence from the weighted normalized combination:

```sql
weighted_rating := (operator_rating_effect * 0.60) + (captain_rating_effect * 0.40);
```

Store the configurable weights in quality configuration, not hard-coded only in a trigger. Store captain/location histories separately. Any rating <=2 creates an attribution-review operational alert.

- [ ] **Step 5: Implement 10:00 a.m. next-local-day scheduling**

Calculate due timestamps with PostgreSQL `AT TIME ZONE` using the country timezone. Insert one `post_journey_feedback` notification per booking. Extend the scheduled endpoint to call this scheduler before claiming emails.

- [ ] **Step 6: Verify timezone and scoring behavior**

Test at least Antigua (`America/Antigua`) and a DST-observing timezone around a clock change. Assert NPS/location values never enter operator weighted effect and captain contribution does.

- [ ] **Step 7: Commit Task 6**

```bash
git add supabase/migrations supabase/tests/journey_feedback_quality_contract.sql supabase/tests/journey_feedback_quality_behavior.sql lib/feedback-email-content.ts lib/data.ts app/api/operations/run-scheduled/route.ts tests/feedback-email-content.test.mjs
git commit -m "feat: collect separated journey quality feedback"
```

---

### Task 7: Feedback form and Site Admin performance reporting

**Files:**
- Create: `components/journey-feedback-form.tsx`
- Create: `components/journey-feedback-form.test.tsx`
- Create: `components/admin-journey-communications.tsx`
- Create: `components/admin-quality-performance.tsx`
- Modify: `components/pages.tsx`
- Modify: `lib/data.ts`
- Modify: `app/globals.css`
- Create: `tests/admin-journey-quality-ui.test.mjs`

**Interfaces:**
- Consumes: Task 6 feedback API/views and Task 1 operational alerts/delivery records.
- Produces: two-minute mobile feedback form; Site Admin communications exceptions; platform/operator/captain/pickup/destination reporting.

- [ ] **Step 1: Write failing feedback-form tests**

Require all six numeric ratings, exact NPS wording, separate positive/improvement comments and unchecked testimonial consent:

```tsx
render(<JourneyFeedbackForm journey={journey} onSubmit={onSubmit}/>);
expect(screen.getByText('How likely are you to recommend Pace Shuttles to a friend?')).toBeTruthy();
expect((screen.getByLabelText(/testimonial/i) as HTMLInputElement).checked).toBe(false);
expect(screen.getByText(/pickup location/i)).toBeTruthy();
expect(screen.getByText(/destination/i)).toBeTruthy();
```

- [ ] **Step 2: Write failing Site Admin contract tests**

Assert UI presence for T-24 overdue, email failure, conversation supervision, NPS, booking experience, captain, pickup and destination metrics, response count/trend/comments and <=2 review alerts.

- [ ] **Step 3: Implement and wire the feedback form**

Open from the email deep link and completed booking card. Prevent double submission in UI while the database unique constraint remains authoritative. Show NPS endpoint labels and submission confirmation.

- [ ] **Step 4: Implement Site Admin communications operations**

Display active/resolved operational alerts, late minutes, delivery failure/provider status, journey conversations and broadcast delivery counts. Add supervised Site Admin reply using Task 3 RPC.

- [ ] **Step 5: Implement quality dashboards**

Use separate sections for:

```text
Pace Shuttles: NPS, promoters/passives/detractors, booking-experience average/trend
Operators: quality score, 60/40 evidence, attribution state
Captains: average, count, trend, recent evidence
Pickups: average, count, trend, country comparison, comments
Destinations: average, count, trend, country comparison, comments
```

- [ ] **Step 6: Verify Task 7**

Run Vitest, Node UI contracts, full `npm test` and production build. Check mobile form completion and Site Admin desktop tables in the browser.

- [ ] **Step 7: Commit Task 7**

```bash
git add components/journey-feedback-form.tsx components/journey-feedback-form.test.tsx components/admin-journey-communications.tsx components/admin-quality-performance.tsx components/pages.tsx lib/data.ts app/globals.css tests/admin-journey-quality-ui.test.mjs
git commit -m "feat: add feedback and journey quality dashboards"
```

---

### Task 8: End-to-end security, scheduling and production readiness

**Files:**
- Create: `supabase/tests/journey_communications_security_contract.sql`
- Create: `supabase/tests/journey_communications_end_to_end.sql`
- Create: `tests/journey-communications-release.test.mjs`
- Modify: `README_CAPTAIN_INTERFACE.md`
- Modify: `README_SERVICE_ACCESS.md`
- Modify: `docs/superpowers/plans/2026-08-30-journey-communications-feedback.md`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: verified release evidence and documented role workflows; no new production feature behavior.

- [ ] **Step 1: Add the complete security matrix test**

Test actual authenticated identities/claims for:

```text
anonymous: no protected reads/writes
customer A: own booking/thread/feedback only
customer B: own booking/thread/feedback only
assigned captain: assigned allocation and its separate party threads
other captain: denied
operator-only user: denied private messages
Site Admin: supervised access and intervention
service role: queue scheduling/claim/mark only through server execution
```

Assert all new security-definer functions have PUBLIC and anon execution revoked and validate user/role internally.

- [ ] **Step 2: Add deterministic end-to-end database scenario**

In a transaction, construct a confirmed captain-backed journey with two paid bookings. Advance `p_as_of` through T-24, actual completion + four hours and next-day 10:00 local time. Assert reminder, private messages, broadcast fan-out, closure and feedback queue/scoring, then roll back.

- [ ] **Step 3: Run every automated check**

```bash
npm test
npm run build
git diff --check
```

Run every `supabase/tests/*.sql` file against the linked non-production test context. Run Supabase advisors and inspect function grants, RLS policies and exposed views.

- [ ] **Step 4: Request independent code and security review**

Review the complete diff against the approved spec, concentrating on message isolation, recipient derivation, timezones, idempotency, allocation locking, quality separation and service-role boundaries. Resolve all high/medium findings and rerun tests.

- [ ] **Step 5: Publish a preview deployment**

Push the reviewed branch, open a PR, wait for Vercel success and apply migrations only to the approved test/preview Supabase context.

- [ ] **Step 6: Verify complete role journeys in the browser**

Using separate test identities:

1. Site Admin confirms captain-backed allocation and sees no exception.
2. Customer A and B each receive the T-24 notification.
3. Customer A contacts the captain; Customer B cannot see it.
4. Captain replies to A and broadcasts to all.
5. Both customers receive private broadcast copies and queued emails.
6. Captain completes the journey; messaging remains open for four hours then closes.
7. At next-day 10:00 local, both feedback requests queue.
8. Customer A submits all ratings; Site Admin sees separated metrics and the operator 60/40 evidence.

Inspect browser console, function logs and email delivery records; exclude only identified browser-extension noise.

- [ ] **Step 7: Obtain explicit production activation approval**

Present PR, migration list, test totals, preview URLs, role-by-role evidence, rollback procedure and any remaining operational caveats. Do not apply production migrations or merge until approval.

- [ ] **Step 8: Activate and verify production**

After approval, apply migrations in order, merge the PR, wait for production Vercel success, invoke a read-only scheduler dry run where supported, and verify live access gates plus one controlled non-delivery test fixture. Remove the fixture through its transactional cleanup and confirm zero residual rows.

- [ ] **Step 9: Commit release documentation**

```bash
git add supabase/tests/journey_communications_security_contract.sql supabase/tests/journey_communications_end_to_end.sql tests/journey-communications-release.test.mjs README_CAPTAIN_INTERFACE.md README_SERVICE_ACCESS.md docs/superpowers/plans/2026-08-30-journey-communications-feedback.md
git commit -m "test: verify journey communications release"
```
