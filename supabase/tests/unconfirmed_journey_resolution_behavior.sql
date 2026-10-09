-- Transactional production-schema regression: changes in this test never commit.
-- Uses an existing unconfirmed paid journey; creates no test journeys or bookings.
do $test$
declare dep uuid; booking uuid; pair uuid; result integer; seats_before integer; refunds_before integer;
begin
  select d.id,b.id,d.journey_pair_id,b.seats into dep,booking,pair,seats_before
  from pace_v2.departures d join pace_v2.bookings b on b.departure_id=d.id
  where d.is_commercial and d.status='at_risk' and b.paid_at is not null
    and d.scheduled_departure_ts<=now() and d.actual_departure_ts is null
    and exists(select 1 from pace_v2.allocation_decisions a where a.departure_id=d.id and a.decision_type='t24_manual_review')
    and not exists(select 1 from pace_v2.confirmed_allocations ca where ca.departure_id=d.id)
  order by d.scheduled_departure_ts desc limit 1;
  if dep is null then raise notice 'No existing unresolved fixture; behavioural recovery test skipped'; return; end if;
  begin
    -- Confirmed journeys must be excluded from automatic cancellation.
    update pace_v2.departures set status='confirmed' where id=dep;
    result:=pace_v2.resolve_unconfirmed_journey_exceptions(dep);
    if result<>0 or (select status from pace_v2.departures where id=dep)<>'confirmed' then
      raise exception 'Confirmed journey was cancelled';
    end if;
    update pace_v2.departures set status='at_risk' where id=dep;
    -- A future unresolved journey must stay available for admin rescue.
    update pace_v2.departures set scheduled_departure_ts=now()+interval '1 hour',
      scheduled_arrival_ts=now()+interval '2 hours' where id=dep;
    result:=pace_v2.resolve_unconfirmed_journey_exceptions(dep);
    if result<>0 then raise exception 'Journey cancelled before departure'; end if;
    update pace_v2.departures set scheduled_departure_ts=now()-interval '1 minute' where id=dep;
    result:=pace_v2.resolve_unconfirmed_journey_exceptions(dep);
    if result<>1 then raise exception 'Unresolved departure was not cancelled'; end if;
    if exists(select 1 from pace_v2.departures where (id=dep or journey_pair_id=pair) and status<>'cancelled') then
      raise exception 'Paired return status is incoherent';
    end if;
    if (select status from pace_v2.bookings where id=booking)<>'cancelled'
       or (select seats from pace_v2.bookings where id=booking)<>seats_before then
      raise exception 'Booking state or whole-party seats incorrect';
    end if;
    if exists(select 1 from pace_v2.booking_allocations where booking_id=booking and status in('preliminary','confirmed')) then
      raise exception 'Stale allocation remains active';
    end if;
    select count(*) into refunds_before from pace_v2.refund_requests where booking_id=booking and status='requested';
    if refunds_before<>1 then raise exception 'Refund review was not requested exactly once'; end if;
    if not exists(select 1 from pace_v2.notifications where booking_id=booking and channel='email'
       and template_code='UNCONFIRMED_JOURNEY_CANCELLED' and status='queued') then
      raise exception 'Customer cancellation email missing';
    end if;
    if not exists(select 1 from pace_v2.notifications where departure_id=dep and channel='email'
       and template_code='UNCONFIRMED_JOURNEY_CANCELLED_ADMIN' and status='queued') then
      raise exception 'Admin escalation email missing';
    end if;
    if exists(select 1 from pace_v2.notifications where booking_id=booking
       and template_code in('JOURNEY_REMINDER_24H','JOURNEY_REMINDER_3H') and status in('pending','queued','failed')) then
      raise exception 'Misleading journey reminders remain sendable';
    end if;
    result:=pace_v2.resolve_unconfirmed_journey_exceptions(dep);
    if result<>0 or (select count(*) from pace_v2.refund_requests where booking_id=booking and status='requested')<>refunds_before then
      raise exception 'Repeated resolution is not idempotent';
    end if;
    insert into pace_v2.notifications(booking_id,departure_id,channel,template_code,subject,body,status,scheduled_at)
    values(booking,dep,'in_app','BOOKING_CONFIRMED','Booking confirmed','Your booking is confirmed','pending',now());
    if not exists(select 1 from pace_v2.notifications where booking_id=booking and channel='email'
      and template_code='BOOKING_CONFIRMED' and created_at=now()
      and subject like '%travel confirmation pending%' and body like '%subject to the minimum operating requirements%') then
      raise exception 'Payment receipt still promises confirmed travel';
    end if;
    set constraints all immediate;
    raise exception using errcode='ZX001',message='rollback successful test';
  exception when sqlstate 'ZX001' then
    raise notice 'PASS: confirmed-journey protection, future rescue, cancellation, return coherence, party integrity, alerts, refund request, reminder suppression, receipt wording and idempotence';
  end;
end $test$;
