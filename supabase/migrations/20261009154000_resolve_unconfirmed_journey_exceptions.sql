-- Paid reservations and final travel confirmation are distinct.
create or replace function pace_v2.queue_journey_exception_emails()
returns trigger language plpgsql security definer set search_path to '' as $$
declare email text; admin record; reason text; details jsonb;
begin
  if new.channel<>'in_app' or new.departure_id is null or new.template_code not in
    ('T72_AT_RISK','T24_CUSTOMER_ACTION_REQUIRED','UNCONFIRMED_JOURNEY_CANCELLED') then return new; end if;
  select coalesce(d.at_risk_reason,d.cancelled_reason,new.body) into reason
  from pace_v2.departures d where d.id=new.departure_id;
  details:=jsonb_build_object('departure_id',new.departure_id,'booking_id',new.booking_id,
    'reason',reason,'trigger',new.template_code,'execution_history','https://www.paceshuttles.com/admin/clock-calendar');
  details:=details||jsonb_build_object(
    'departure',(select to_jsonb(d) from pace_v2.departures d where d.id=new.departure_id),
    'decision',(select to_jsonb(a) from pace_v2.allocation_decisions a where a.departure_id=new.departure_id order by a.created_at desc limit 1),
    'booking_seats',(select sum(b.seats) from pace_v2.bookings b where b.departure_id=new.departure_id),
    'paid_booking_value_cents',(select sum(b.total_price_cents) from pace_v2.bookings b where b.departure_id=new.departure_id and b.paid_at is not null));
  insert into pace_v2.operational_alerts(exception_key,exception_type,severity,departure_id,details)
  values(new.template_code||':'||new.departure_id::text,'unconfirmed_journey','high',new.departure_id,details)
  on conflict(exception_key) where resolved_at is null do update set details=excluded.details;
  if new.booking_id is not null then
    select o.customer_email into email from pace_v2.bookings b
    join pace_v2.orders o on o.id=b.order_id where b.id=new.booking_id;
    if pace_v2.is_valid_customer_notification_email(email) and not exists (
      select 1 from pace_v2.notifications n where n.booking_id=new.booking_id
      and n.departure_id=new.departure_id and n.channel='email' and n.template_code=new.template_code
    ) then
      insert into pace_v2.notifications(booking_id,departure_id,channel,to_email,template_code,subject,body,status,scheduled_at,metadata)
      values(new.booking_id,new.departure_id,'email',email,new.template_code,new.subject,
        new.body||chr(10)||'Booking reference: '||new.booking_id::text||chr(10)||'Journey ID: '||new.departure_id::text
        ||chr(10)||'Manage your booking: https://www.paceshuttles.com/customer','queued',now(),details) on conflict do nothing;
    end if;
  end if;
  for admin in select distinct lower(trim(u.email)) email from pace_v2.profiles p
    join auth.users u on u.id=p.user_id where p.platform_role='site_admin'
    and u.deleted_at is null and (u.banned_until is null or u.banned_until<=now())
    and pace_v2.is_valid_customer_notification_email(u.email)
    and lower(u.email) !~ '@[^@]+[.](test|invalid|example)$'
  loop
    if not exists(select 1 from pace_v2.notifications n where n.departure_id=new.departure_id
      and n.template_code=new.template_code||'_ADMIN' and n.to_email=admin.email) then
      insert into pace_v2.notifications(departure_id,channel,to_email,template_code,subject,body,status,scheduled_at,metadata)
      values(new.departure_id,'email',admin.email,new.template_code||'_ADMIN',
        'ACTION REQUIRED: Pace Shuttles unconfirmed journey',
        'Journey ID: '||new.departure_id::text||chr(10)||'Reason: '||reason||chr(10)
        ||'Impact: No confirmed travel arrangement. Review paid bookings and refund requests.'||chr(10)
        ||'Action: Resolve the operating arrangement before departure or complete cancellation and refund review.'||chr(10)
        ||'Execution history: https://www.paceshuttles.com/admin/clock-calendar'||chr(10)||'Evidence: '||details::text,
        'queued',now(),details) on conflict do nothing;
    end if;
  end loop;
  return new;
end $$;
drop trigger if exists journey_exception_emails on pace_v2.notifications;
create unique index if not exists journey_exception_email_once
on pace_v2.notifications(departure_id,coalesce(booking_id,'00000000-0000-0000-0000-000000000000'::uuid),template_code,to_email)
where channel='email' and template_code in('T72_AT_RISK','T24_CUSTOMER_ACTION_REQUIRED','UNCONFIRMED_JOURNEY_CANCELLED',
  'T72_AT_RISK_ADMIN','T24_CUSTOMER_ACTION_REQUIRED_ADMIN','UNCONFIRMED_JOURNEY_CANCELLED_ADMIN');
create trigger journey_exception_emails after insert on pace_v2.notifications
for each row execute function pace_v2.queue_journey_exception_emails();

create or replace function pace_v2.normalize_booking_receipt()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if new.channel='in_app' and new.template_code='BOOKING_CONFIRMED' and not exists (
    select 1 from pace_v2.bookings b join pace_v2.departures d on d.id=b.departure_id
    join pace_v2.confirmed_allocations ca on ca.departure_id=d.id and ca.status='confirmed'
    join pace_v2.booking_allocations ba on ba.booking_id=b.id and ba.vehicle_id=ca.vehicle_id
      and ba.seats=b.seats and ba.status='confirmed'
    join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
    join pace_v2.captains c on c.id=a.captain_id and c.active
    where b.id=new.booking_id and d.status='confirmed'
  ) then
    new.subject:='Booking received — travel confirmation pending';
    new.body:='Payment received. Your booking is recorded and your party will be kept together. Travel is subject to minimum operating requirements and final vehicle and captain confirmation at T-24 (24 hours before departure).';
  end if;
  return new;
end $$;
drop trigger if exists normalize_booking_receipt on pace_v2.notifications;
create trigger normalize_booking_receipt before insert on pace_v2.notifications
for each row execute function pace_v2.normalize_booking_receipt();

create or replace function pace_v2.resolve_unconfirmed_journey_exceptions(p_departure_id uuid default null)
returns integer language plpgsql security definer set search_path to '' as $$
declare d record; b record; count_cancelled integer:=0; reason text;
begin
  update pace_v2.booking_allocations ba set status='released',released_at=now(),
    allocation_reason='Released — vehicle is no longer viable after the operating cutoff.'
  from pace_v2.vehicle_considerations vc,pace_v2.departures dep
  where vc.id=ba.vehicle_consideration_id and dep.id=ba.departure_id
    and (p_departure_id is null or dep.id=p_departure_id)
    and dep.status='at_risk' and ba.status in('preliminary','confirmed')
    and vc.status in('discarded_t72','withdrawn','cancelled','replaced')
    and not exists(select 1 from pace_v2.confirmed_allocations ca where ca.departure_id=dep.id
      and ca.vehicle_id=ba.vehicle_id and ca.status in('confirmed','completed'));
  for d in select dep.* from pace_v2.departures dep
    where dep.is_commercial and dep.status='at_risk' and dep.scheduled_departure_ts<=now()
    and (p_departure_id is null or dep.id=p_departure_id)
    and dep.actual_departure_ts is null and dep.actual_arrival_ts is null
    and exists(select 1 from pace_v2.allocation_decisions ad where ad.departure_id=dep.id
      and ad.decision_type='t24_manual_review')
    and not exists(select 1 from pace_v2.confirmed_allocations ca where ca.departure_id in (
      select pd.id from pace_v2.departures pd where pd.id=dep.id
        or (dep.journey_pair_id is not null and pd.journey_pair_id=dep.journey_pair_id)
    ) and ca.status in('confirmed','completed'))
    and not exists(select 1 from pace_v2.departures pd where pd.journey_pair_id=dep.journey_pair_id
      and (pd.actual_departure_ts is not null or pd.actual_arrival_ts is not null))
    and not exists(select 1 from pace_v2.captain_leg_operations op join pace_v2.departures pd on pd.id=op.departure_id
      where (pd.id=dep.id or pd.journey_pair_id=dep.journey_pair_id) and op.started_at is not null)
    order by dep.scheduled_departure_ts limit 100 for update of dep skip locked
  loop
    reason:='Cancelled — departure reached without a viable confirmed vehicle and captain.';
    update pace_v2.departures set status='cancelled',cancelled_reason=reason,
      at_risk_reason=null,closed_at=now(),closure_reason=reason,updated_at=now()
    where id=d.id or (journey_pair_id=d.journey_pair_id and not is_commercial
      and status in('scheduled','selling','at_risk','under_consideration')
      and actual_departure_ts is null and actual_arrival_ts is null);
    update pace_v2.captain_duty_reservations set state='released',released_at=now(),release_reason=reason
    where departure_id=d.id and state in('provisional','held_t72');
    for b in select bk.* from pace_v2.bookings bk where bk.departure_id=d.id
      and bk.status in('booked','at_risk','confirmed') for update
    loop
      update pace_v2.bookings set status='cancelled',updated_at=now() where id=b.id;
      update pace_v2.booking_allocations set status='released',released_at=coalesce(released_at,now()),allocation_reason=reason
      where booking_id=b.id and status in('preliminary','confirmed');
      if b.paid_at is not null and b.total_price_cents>0 and not exists (
        select 1 from pace_v2.refund_requests rr where rr.booking_id=b.id and rr.status in('requested','approved','paid')
      ) then
        insert into pace_v2.refund_requests(booking_id,order_id,currency,requested_refund_cents,status,reason,requested_by)
        values(b.id,b.order_id,b.currency,b.total_price_cents,'requested',reason,'system');
      end if;
      update pace_v2.notifications set status='cancelled',failure_message='Suppressed — journey was not confirmed.'
      where booking_id=b.id and status in('pending','queued','failed')
      and template_code in('JOURNEY_REMINDER_24H','JOURNEY_REMINDER_3H','journey_tomorrow','journey_captain_pending','T72_AT_RISK','T24_CUSTOMER_ACTION_REQUIRED');
      perform pace_v2.queue_notification(null,b.id,d.id,'in_app','UNCONFIRMED_JOURNEY_CANCELLED',
        'Your Pace Shuttles journey has been cancelled',
        'Your journey could not meet its operating requirements and has been cancelled. Please do not travel to the pickup point. Any payment is awaiting refund review; we will confirm when the refund has been processed.',d.scheduled_departure_ts);
    end loop;
    insert into pace_v2.allocation_decisions(departure_id,decision_type,engine_version,decision_reason_code,decision_reason_text,input_snapshot,candidate_snapshot,commercial_snapshot)
    values(d.id,'unconfirmed_departure_cancelled','exception-resolution-v1','UNCONFIRMED_AT_DEPARTURE',reason,
      jsonb_build_object('previous_at_risk_reason',d.at_risk_reason,'refunds_requested',true,'travel_recorded',false),'[]'::jsonb,'{}'::jsonb);
    update pace_v2.operational_alerts set resolved_at=now(),resolution_note=reason||' Refund review remains outstanding.'
    where departure_id=d.id and resolved_at is null
      and exception_key in('T72_AT_RISK:'||d.id::text,'T24_CUSTOMER_ACTION_REQUIRED:'||d.id::text);
    count_cancelled:=count_cancelled+1;
  end loop;
  return count_cancelled;
end $$;
revoke all on function pace_v2.queue_journey_exception_emails(),pace_v2.normalize_booking_receipt(),pace_v2.resolve_unconfirmed_journey_exceptions(uuid) from public,anon,authenticated;
grant execute on function pace_v2.resolve_unconfirmed_journey_exceptions(uuid) to service_role;
CREATE OR REPLACE FUNCTION pace_v2.queue_customer_email_for_notification()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pace_v2', 'public'
AS $function$
declare
  v_email text;
  v_existing uuid;
  x record;
  v_body text;
  v_final boolean;
begin
  if new.booking_id is null
     or new.channel<>'in_app'
     or new.template_code<>'BOOKING_CONFIRMED' then
    return new;
  end if;

  select o.customer_email
  into v_email
  from pace_v2.bookings b
  join pace_v2.orders o on o.id=b.order_id
  where b.id=new.booking_id;

  if not pace_v2.is_valid_customer_notification_email(v_email) then
    return new;
  end if;

  select exists (
    select 1 from pace_v2.bookings b
    join pace_v2.departures d on d.id=b.departure_id
    join pace_v2.booking_allocations ba on ba.booking_id=b.id and ba.status='confirmed' and ba.seats=b.seats
    join pace_v2.confirmed_allocations ca on ca.departure_id=d.id and ca.vehicle_id=ba.vehicle_id and ca.status='confirmed'
    join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
    join pace_v2.captains c on c.id=a.captain_id and c.active
    where b.id=new.booking_id and d.status='confirmed'
  ) into v_final;
  v_body:=new.body;
  select
    b.id as booking_id,o.customer_name,r.route_name,
    p.name as pickup_name,dst.name as destination_name,
    d.scheduled_departure_ts,d.trip_timezone,b.seats,o.total_cents,o.currency,
    c.name as country_name,t.version as terms_version
  into x
  from pace_v2.bookings b
  join pace_v2.orders o on o.id=b.order_id
  join pace_v2.departures d on d.id=b.departure_id
  join pace_v2.routes r on r.id=b.route_id
  join pace_v2.pickup_points p on p.id=r.pickup_id
  join pace_v2.destinations dst on dst.id=r.destination_id
  join pace_v2.countries c on c.id=r.country_id
  join pace_v2.country_terms t on t.country_id=c.id and t.is_active=true
  where b.id=new.booking_id
  order by t.effective_from desc
  limit 1;

  if x.booking_id is not null then
    v_body:='Hello '||coalesce(nullif(trim(x.customer_name),''),'there')||E',\n\n'
      ||case when v_final then 'Your Pace Shuttles journey is confirmed. Your whole party has been allocated together.'
      else 'Payment has been received and your booking is recorded. Travel is subject to the minimum operating requirements and final vehicle and captain confirmation at 24 hours before departure. Please wait for your final itinerary before treating travel as confirmed.' end||E'\n\n'
      ||'Booking reference: '||x.booking_id::text||E'\n'
      ||'Journey: '||x.route_name||E'\n'
      ||'Pickup: '||x.pickup_name||E'\n'
      ||'Destination: '||x.destination_name||E'\n'
      ||'Departure: '||to_char(
        x.scheduled_departure_ts at time zone coalesce(nullif(x.trip_timezone,''),'UTC'),
        'Dy DD Mon YYYY, HH12:MI AM'
      )||E'\n'
      ||'Passengers / seats: '||x.seats||E'\n'
      ||'Amount paid: $'||to_char(x.total_cents/100.0,'FM999999990.00')||' '||x.currency||E'\n\n'
      ||'Manage your journey: https://paceshuttles.com/customer'||E'\n'
      ||'Terms & Conditions: https://paceshuttles.com/legal/terms?country='
      ||replace(lower(x.country_name),' ','-')||E'\n'
      ||'Applicable terms version: '||x.terms_version||' ('||x.country_name||')'||E'\n\n'
      ||'Please check My Journeys for the latest pickup, arrival and journey information.'||E'\n\n'
      ||'Thank you for travelling with Pace Shuttles.'||E'\n'
      ||'Pace Shuttles';
  end if;

  select n.id
  into v_existing
  from pace_v2.notifications n
  where n.booking_id=new.booking_id
    and coalesce(n.departure_id,'00000000-0000-0000-0000-000000000000'::uuid)
      =coalesce(new.departure_id,'00000000-0000-0000-0000-000000000000'::uuid)
    and n.channel='email'
    and n.template_code='BOOKING_CONFIRMED'
    and coalesce(n.scheduled_at,'epoch'::timestamptz)
      =coalesce(new.scheduled_at,'epoch'::timestamptz)
  limit 1;

  if v_existing is null then
    insert into pace_v2.notifications(
      recipient_user_id,booking_id,departure_id,channel,template_code,
      subject,body,status,to_email,scheduled_at
    ) values (
      new.recipient_user_id,new.booking_id,new.departure_id,'email',
      'BOOKING_CONFIRMED',case when v_final then 'Your Pace Shuttles journey is confirmed' else 'Your Pace Shuttles booking has been received — travel confirmation pending' end,
      v_body,'queued',v_email,new.scheduled_at
    );
  end if;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION pace_v2.process_departure_t72(p_departure_id uuid, p_engine_version text DEFAULT 'scheduler-v1.3'::text, p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pace_v2', 'public'
AS $function$
declare
  d pace_v2.departures%rowtype;
  jr uuid;
  booking_count integer;
  result jsonb;
  r record;
begin
  select * into d from pace_v2.departures where id=p_departure_id for update;
  if not found then raise exception 'Departure not found'; end if;
  if not d.is_commercial then return jsonb_build_object('outcome','not_commercial'); end if;
  if not p_force and now()<d.t72_ts then return jsonb_build_object('outcome','not_due'); end if;

  insert into pace_v2.scheduled_job_runs(
    job_name,departure_id,phase,scheduled_for,engine_version
  ) values('departure_window_processor',d.id,'t72',d.t72_ts,p_engine_version)
  on conflict do nothing returning id into jr;
  if jr is null then return jsonb_build_object('outcome','already_processed'); end if;

  begin
    select coalesce(sum(booking.seats),0) into booking_count
    from pace_v2.bookings booking
    where booking.departure_id=d.id
      and booking.status in('booked','at_risk','confirmed');

    if booking_count=0 then
      update pace_v2.vehicle_considerations
      set status='cancelled',updated_at=now()
      where departure_id=d.id and status not in('withdrawn','replaced','cancelled');
      update pace_v2.departures
      set status='cancelled',cancelled_reason='Cancelled at T-72 — no bookings.',
          at_risk_reason=null
      where id=d.id;
      insert into pace_v2.allocation_decisions(
        departure_id,decision_type,engine_version,decision_reason_code,
        decision_reason_text,input_snapshot,candidate_snapshot,commercial_snapshot
      ) values(
        d.id,'t72_zero_booking',p_engine_version,'CANCELLED_NO_BOOKINGS_T72',
        'Cancelled at T-72 — no bookings.',jsonb_build_object('booked_seats',0),
        coalesce((select jsonb_agg(jsonb_build_object(
          'consideration_id',consideration.id,'vehicle_id',consideration.vehicle_id,
          'operator_id',consideration.operator_id,'resulting_status',consideration.status
        )) from pace_v2.vehicle_considerations consideration
        where consideration.departure_id=d.id),'[]'::jsonb),'{}'::jsonb
      );
      result:=jsonb_build_object('outcome','cancelled_no_bookings',
        'reason','Cancelled at T-72 — no bookings.');
    else
      perform pace_v2.refresh_vehicle_considerations(d.id,p_engine_version);
      select to_jsonb(evaluation) into result
      from pace_v2.evaluate_t72_booked_parties(d.id,p_engine_version) evaluation;

      for r in
        select distinct consideration.operator_id
        from pace_v2.vehicle_considerations consideration
        join pace_v2.captain_duty_reservations reservation
          on reservation.vehicle_consideration_id=consideration.id
         and reservation.state='held_t72'
        where consideration.departure_id=d.id
          and consideration.status='under_consideration'
      loop
        perform pace_v2.queue_notification(
          r.operator_id,null,d.id,'in_app','T72_UNDER_CONSIDERATION',
          'Journey under consideration',
          'One or more staffed vehicles are under consideration for this journey.',
          d.t72_ts
        );
      end loop;

      if exists(
        select 1 from pace_v2.departures departure
        where departure.id=d.id and departure.status='at_risk'
      ) then
        for r in
          select booking.id from pace_v2.bookings booking
          where booking.departure_id=d.id
            and booking.status in('booked','at_risk','confirmed')
        loop
          perform pace_v2.queue_notification(
            null,r.id,d.id,'in_app','T72_AT_RISK','Journey update',
            'Your journey is currently at risk. Pace Shuttles is working to confirm the service.',
            d.t72_ts
          );
        end loop;
      end if;
    end if;

    perform pace_v2.resolve_unconfirmed_journey_exceptions(d.id);
    update pace_v2.scheduled_job_runs
    set status='completed',completed_at=now(),outcome=coalesce(result,'{}'::jsonb)
    where id=jr;
    return coalesce(result,'{}'::jsonb);
  exception when others then
    update pace_v2.scheduled_job_runs
    set status='failed',completed_at=now(),failure_message=sqlerrm
    where id=jr;
    raise;
  end;
end
$function$;

CREATE OR REPLACE FUNCTION pace_v2.process_departure_t24(p_departure_id uuid, p_engine_version text DEFAULT 'scheduler-v1.5'::text, p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  d pace_v2.departures%rowtype;
  jr uuid;
  result jsonb;
  r record;
  consolidated_party_count integer:=0;
begin
  select * into d
  from pace_v2.departures
  where id=p_departure_id
  for update;

  if not found then raise exception 'Departure not found'; end if;

  if not p_force and now()<d.t24_ts then
    return jsonb_build_object('outcome','not_due');
  end if;

  insert into pace_v2.scheduled_job_runs(
    job_name,departure_id,phase,scheduled_for,engine_version
  ) values(
    'departure_window_processor',d.id,'t24',d.t24_ts,p_engine_version
  )
  on conflict (job_name,departure_id,phase,scheduled_for) do update
  set started_at=now(),
      completed_at=null,
      status='running',
      outcome='{}'::jsonb,
      failure_message=null,
      engine_version=excluded.engine_version
  where pace_v2.scheduled_job_runs.started_at < pace_v2.scheduled_job_runs.scheduled_for
    and now() >= pace_v2.scheduled_job_runs.scheduled_for
  returning id into jr;

  if jr is null then
    return jsonb_build_object('outcome','already_processed');
  end if;

  begin
    if exists (
      select 1
      from pace_v2.bookings b
      left join pace_v2.booking_allocations ba
        on ba.booking_id=b.id
       and ba.status in ('preliminary','confirmed')
       and ba.seats=b.seats
      left join pace_v2.vehicle_considerations vc
        on vc.id=ba.vehicle_consideration_id
       and vc.departure_id=d.id
       and vc.status='under_consideration'
       and vc.assigned_seats>=vc.normal_min_seats
       and vc.assigned_revenue_cents>=pace_v2.required_consideration_revenue_cents(
         vc.min_revenue_cents,
         vc.min_value_threshold_ratio,
         vc.below_minimum_operation_mode
       )
      where b.departure_id=d.id
        and b.status in ('booked','at_risk','confirmed')
      group by b.id
      having count(ba.id)<>1 or count(vc.id)<>1
    ) then
      update pace_v2.departures
      set status='at_risk',
          at_risk_reason='T-24 confirmation requires manual review: one or more booking parties are not covered by a viable vehicle.',
          updated_at=now()
      where id=d.id;

      update pace_v2.bookings
      set status='at_risk',updated_at=now()
      where departure_id=d.id and status in ('booked','confirmed');

      update pace_v2.departure_revenue_gap_rescues
      set status='cancelled',resolved_at=now(),
          resolution='T-24 reached with incomplete whole-party vehicle coverage; manual review required.'
      where departure_id=d.id and status='open';

      insert into pace_v2.allocation_decisions(
        departure_id,decision_type,engine_version,
        decision_reason_code,decision_reason_text,
        input_snapshot,candidate_snapshot,commercial_snapshot,
        quality_snapshot,fairness_snapshot
      ) values (
        d.id,'t24_manual_review',p_engine_version,
        'T24_INCOMPLETE_BOOKING_COVERAGE',
        'T-24 confirmation was not attempted because one or more whole booking parties were not allocated to a viable vehicle. Manual review is required.',
        jsonb_build_object('manual_review_required',true),
        coalesce((
          select jsonb_agg(jsonb_build_object(
            'booking_id',b.id,
            'booking_status',b.status,
            'allocated_consideration_id',ba.vehicle_consideration_id,
            'consideration_status',vc.status
          ) order by b.id)
          from pace_v2.bookings b
          left join pace_v2.booking_allocations ba
            on ba.booking_id=b.id
           and ba.status in ('preliminary','confirmed')
           and ba.seats=b.seats
          left join pace_v2.vehicle_considerations vc
            on vc.id=ba.vehicle_consideration_id
          where b.departure_id=d.id
            and b.status in ('booked','at_risk','confirmed')
        ),'[]'::jsonb),
        jsonb_build_object('customer_prices_changed',false),
        '{}'::jsonb,'{}'::jsonb
      );

      for r in
        select b.id
        from pace_v2.bookings b
        where b.departure_id=d.id
          and b.status in ('booked','at_risk','confirmed')
      loop
        perform pace_v2.queue_notification(
          null,r.id,d.id,'in_app','T24_CUSTOMER_ACTION_REQUIRED',
          'Important journey update',
          'Your journey requires manual review before it can be confirmed.',
          d.t24_ts
        );
      end loop;

      result:=jsonb_build_object(
        'outcome','at_risk_manual_review',
        'reason_code','T24_INCOMPLETE_BOOKING_COVERAGE',
        't24_consolidated_party_count',0
      );

      perform pace_v2.resolve_unconfirmed_journey_exceptions(d.id);
      update pace_v2.scheduled_job_runs
      set status='completed',completed_at=now(),outcome=result
      where id=jr;

      return result;
    end if;

    consolidated_party_count:=pace_v2.consolidate_departure_fleet_t24(
      d.id,
      p_engine_version
    );

    -- Do not begin confirmation when an operator cannot provide one distinct,
    -- eligible captain for every simultaneous surviving vehicle. The deferred
    -- allocation constraint would otherwise abort the entire scheduler run.
    if exists (
      with required as (
        select vc.operator_id,v.vehicle_type_id,count(*)::integer vehicle_count
        from pace_v2.vehicle_considerations vc
        join pace_v2.vehicles v on v.id=vc.vehicle_id and v.active
        where vc.departure_id=d.id
          and vc.status='under_consideration'
          and vc.assigned_seats>0
        group by vc.operator_id,v.vehicle_type_id
      ), available as (
        select req.operator_id,req.vehicle_type_id,
          count(distinct cap.id)::integer captain_count
        from required req
        left join pace_v2.captains cap
          on cap.operator_id=req.operator_id and cap.active
        left join pace_v2.captain_vehicle_types cvt
          on cvt.captain_id=cap.id
         and cvt.vehicle_type_id=req.vehicle_type_id and cvt.active
        where cvt.captain_id is not null
        group by req.operator_id,req.vehicle_type_id
      )
      select 1
      from required req
      left join available av
        on av.operator_id=req.operator_id
       and av.vehicle_type_id=req.vehicle_type_id
      where coalesce(av.captain_count,0)<req.vehicle_count
    ) then
      update pace_v2.departures
      set status='at_risk',
          at_risk_reason='T-24 confirmation requires manual review: insufficient eligible captains for the surviving vehicles.',
          updated_at=now()
      where id=d.id;

      update pace_v2.bookings
      set status='at_risk',updated_at=now()
      where departure_id=d.id and status in ('booked','confirmed');

      insert into pace_v2.allocation_decisions(
        departure_id,decision_type,engine_version,
        decision_reason_code,decision_reason_text,
        input_snapshot,candidate_snapshot,commercial_snapshot,
        quality_snapshot,fairness_snapshot
      ) values (
        d.id,'t24_manual_review',p_engine_version,
        'T24_INSUFFICIENT_CAPTAINS',
        'T-24 confirmation was withheld because there were not enough distinct eligible captains for all simultaneous surviving vehicles.',
        jsonb_build_object('manual_review_required',true),
        coalesce((
          select jsonb_agg(jsonb_build_object(
            'consideration_id',vc.id,'operator_id',vc.operator_id,
            'vehicle_id',vc.vehicle_id,'assigned_seats',vc.assigned_seats
          ) order by vc.id)
          from pace_v2.vehicle_considerations vc
          where vc.departure_id=d.id
            and vc.status='under_consideration'
            and vc.assigned_seats>0
        ),'[]'::jsonb),
        jsonb_build_object('customer_prices_changed',false),
        '{}'::jsonb,'{}'::jsonb
      );

      for r in
        select b.id
        from pace_v2.bookings b
        where b.departure_id=d.id
          and b.status in ('booked','at_risk','confirmed')
      loop
        perform pace_v2.queue_notification(
          null,r.id,d.id,'in_app','T24_CUSTOMER_ACTION_REQUIRED',
          'Important journey update',
          'Your journey requires manual review before it can be confirmed.',
          d.t24_ts
        );
      end loop;

      result:=jsonb_build_object(
        'outcome','at_risk_manual_review',
        'reason_code','T24_INSUFFICIENT_CAPTAINS',
        't24_consolidated_party_count',consolidated_party_count
      );

      perform pace_v2.resolve_unconfirmed_journey_exceptions(d.id);
      update pace_v2.scheduled_job_runs
      set status='completed',completed_at=now(),outcome=result
      where id=jr;

      return result;
    end if;

    select to_jsonb(x) || jsonb_build_object(
      't24_consolidated_party_count',consolidated_party_count
    )
    into result
    from pace_v2.confirm_departure_t24(
      d.id,
      p_force,
      p_engine_version
    ) x;

    for r in
      select distinct ca.operator_id
      from pace_v2.confirmed_allocations ca
      where ca.departure_id=d.id and ca.status='confirmed'
    loop
      perform pace_v2.queue_notification(
        r.operator_id,null,d.id,'in_app','T24_OPERATOR_CONFIRMED',
        'Journey confirmed',
        'Your vehicle has been confirmed for this journey.',d.t24_ts
      );
    end loop;

    for r in
      select b.id,d2.status as departure_status
      from pace_v2.bookings b
      join pace_v2.departures d2 on d2.id=b.departure_id
      where b.departure_id=d.id
        and b.status in ('booked','at_risk','confirmed')
    loop
      if r.departure_status='confirmed' then
        perform pace_v2.queue_notification(
          null,r.id,d.id,'in_app','T24_CUSTOMER_CONFIRMED',
          'Journey confirmed','Your Pace Shuttles journey is confirmed.',d.t24_ts
        );
      elsif r.departure_status in ('at_risk','cancelled') then
        perform pace_v2.queue_notification(
          null,r.id,d.id,'in_app','T24_CUSTOMER_ACTION_REQUIRED',
          'Important journey update',
          'Your journey could not be normally confirmed. Please review the latest Pace Shuttles update.',
          d.t24_ts
        );
      end if;
    end loop;

    update pace_v2.scheduled_job_runs
    set status='completed',completed_at=now(),outcome=coalesce(result,'{}'::jsonb)
    where id=jr;

    return coalesce(result,'{}'::jsonb);
  exception when others then
    update pace_v2.scheduled_job_runs
    set status='failed',completed_at=now(),failure_message=sqlerrm
    where id=jr;
    raise;
  end;
end;
$function$;

CREATE OR REPLACE FUNCTION public.v2_system_run_scheduled_operations(p_t72_limit integer DEFAULT 50, p_t24_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pace_v2'
AS $function$
declare
  r record;
  v_t72 integer:=0;
  v_t24 integer:=0;
  v_failed integer:=0;
  v_generated integer:=0;
  v_past_cancelled integer:=0;
  v_closed_count integer:=0;
  v_generation_date date;
  v_result jsonb;
  v_unconfirmed_cancelled integer:=0;
begin
  with horizon_dates as (
    select generated_at::date as service_date
    from generate_series(current_date+340,current_date+380,interval '1 day') generated_at
  )
  select h.service_date into v_generation_date
  from horizon_dates h
  where exists(
    select 1 from pace_v2.services s
    where s.active
      and (s.valid_from is null or s.valid_from<=h.service_date)
      and (s.valid_to is null or s.valid_to>=h.service_date)
      and extract(isodow from h.service_date)::smallint=any(s.days_of_week)
      and (
        s.recurrence_interval_weeks=1 or s.recurrence_anchor_date is null
        or floor((h.service_date-s.recurrence_anchor_date)::numeric/7)::integer
           % s.recurrence_interval_weeks=0
      )
      and not exists(
        select 1 from pace_v2.departures d
        where d.service_id=s.id and d.local_departure_date=h.service_date
      )
  )
  order by h.service_date
  limit 1;

  if v_generation_date is not null then
    select count(*) filter(where g.inserted) into v_generated
    from pace_v2.generate_departures(v_generation_date,v_generation_date) g;
  end if;

  for r in
    select d.id from pace_v2.departures d
    where d.is_commercial
      and d.t72_ts<=now() and d.t24_ts>now()
      and d.status not in('completed','cancelled','closed_unrecorded','confirmed')
      and not exists(
        select 1 from pace_v2.scheduled_job_runs j
        where j.departure_id=d.id and j.phase='t72'
      )
    order by d.t72_ts
    limit greatest(1,least(coalesce(p_t72_limit,50),200))
  loop
    begin
      v_result:=pace_v2.process_departure_t72(r.id,'cron-v1.3',false);
      v_t72:=v_t72+1;
    exception when others then
      v_failed:=v_failed+1;
    end;
  end loop;

  for r in
    select d.id from pace_v2.departures d
    where d.is_commercial
      and d.t24_ts<=now()
      and d.status not in('completed','cancelled','closed_unrecorded','confirmed')
      and not exists(
        select 1 from pace_v2.scheduled_job_runs j
        where j.departure_id=d.id and j.phase='t24'
      )
    order by d.t24_ts
    limit greatest(1,least(coalesce(p_t24_limit,50),200))
  loop
    begin
      v_result:=pace_v2.process_departure_t24(r.id,'cron-v1.3',false);
      v_t24:=v_t24+1;
    exception when others then
      v_failed:=v_failed+1;
    end;
  end loop;

  v_unconfirmed_cancelled:=pace_v2.resolve_unconfirmed_journey_exceptions();

  with targets as (
    select d.id from pace_v2.departures d
    where d.is_commercial
      and d.status not in('completed','cancelled','closed_unrecorded')
      and coalesce(d.scheduled_arrival_ts,d.scheduled_departure_ts+interval '8 hours')
          +interval '24 hours'<=now()
      and not exists(
        select 1 from pace_v2.bookings b
        where b.departure_id=d.id and b.status in('booked','at_risk','confirmed')
      )
    order by d.scheduled_departure_ts
    limit 100
  )
  update pace_v2.departures d
  set status='cancelled',
      cancelled_reason=coalesce(d.cancelled_reason,'Closed after departure — no bookings.'),
      at_risk_reason=null
  from targets t where d.id=t.id;
  get diagnostics v_past_cancelled=row_count;

  with targets as (
    select d.id from pace_v2.departures d
    where d.status not in('completed','cancelled','closed_unrecorded')
      and d.actual_arrival_ts is null
      and coalesce(d.scheduled_arrival_ts,d.scheduled_departure_ts+interval '8 hours')
          +interval '24 hours'<=now()
      and (
        (d.is_commercial and exists(
          select 1 from pace_v2.bookings b
          where b.departure_id=d.id and b.status in('booked','at_risk','confirmed')
        ))
        or (not d.is_commercial and d.journey_pair_id is not null and exists(
          select 1
          from pace_v2.departures paired
          join pace_v2.bookings b on b.departure_id=paired.id
          where paired.journey_pair_id=d.journey_pair_id
            and b.status in('booked','at_risk','confirmed','completed')
        ))
      )
    order by d.scheduled_departure_ts
    limit 100
  )
  update pace_v2.departures d
  set status='closed_unrecorded'::pace_v2.departure_status,
      closed_at=now(),
      closure_reason='Closed — travel outcome unrecorded',
      at_risk_reason=null
  from targets t where d.id=t.id;
  get diagnostics v_closed_count=row_count;

  return jsonb_build_object(
    'generated_departures',v_generated,
    'generation_date',v_generation_date,
    't72_processed',v_t72,
    't24_processed',v_t24,
    'past_empty_cancelled',v_past_cancelled,
    'closed_unrecorded',v_closed_count,
    'unconfirmed_cancelled',v_unconfirmed_cancelled,
    'failed',v_failed,
    'ran_at',now()
  );
end
$function$;
