-- Accrue once inside genuine completion. Never approve or pay automatically.
begin;
CREATE OR REPLACE FUNCTION pace_v2.create_settlement_for_allocation(p_confirmed_allocation_id uuid, p_due_at timestamp with time zone DEFAULT now())
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pace_v2', 'public'
AS $function$
declare
  ca pace_v2.confirmed_allocations%rowtype;
  sid uuid;
  txn uuid;
  op_account uuid;
  commission_account uuid;
  clearing_account uuid;
begin
  select * into ca
  from pace_v2.confirmed_allocations
  where id=p_confirmed_allocation_id
  for update;

  if not found then
    raise exception 'Confirmed allocation % not found',p_confirmed_allocation_id;
  end if;

  if ca.status <> 'completed' then
    raise exception 'Allocation % must be completed before settlement',p_confirmed_allocation_id;
  end if;

  select s.id into sid
  from pace_v2.settlements s
  where s.confirmed_allocation_id=p_confirmed_allocation_id;

  if sid is not null then
    perform pace_v2.apply_operator_liabilities_to_settlement(sid);
    return sid;
  end if;

  select id into op_account
  from pace_v2.ledger_accounts
  where operator_id=ca.operator_id
    and account_type='operator_payable'
    and currency='USD'
    and active
  order by created_at limit 1;

  select id into commission_account
  from pace_v2.ledger_accounts
  where account_code='PS-COMMISSION' and currency='USD' and active;

  select id into clearing_account
  from pace_v2.ledger_accounts
  where account_code='PS-CLEARING' and currency='USD' and active;

  if op_account is null or commission_account is null or clearing_account is null then
    raise exception 'Settlement accrual requires active USD operator payable, PS-COMMISSION and PS-CLEARING ledger accounts';
  end if;



  insert into pace_v2.settlements(
    confirmed_allocation_id,operator_id,journey_value_cents,
    effective_commission_bps,commission_cents,operator_earning_cents,
    adjustment_cents,replacement_cost_liability_cents,
    cancellation_fee_cents,net_payable_cents,currency,status,due_at
  )
  values(
    ca.id,ca.operator_id,ca.operator_journey_value_cents,
    ca.effective_commission_bps,ca.pace_shuttles_commission_cents,
    ca.operator_net_before_adjustments_cents,
    0,0,0,ca.operator_net_before_adjustments_cents,'USD','pending',p_due_at
  )
  returning id into sid;

  insert into pace_v2.ledger_transactions(
    transaction_type,departure_id,confirmed_allocation_id,settlement_id,
    description,idempotency_key
  )
  values(
    'journey_settlement_accrual',ca.departure_id,ca.id,sid,
    'Completed journey settlement accrual',
    'settlement-accrual:'||ca.id::text
  )
  on conflict (idempotency_key) do nothing
  returning id into txn;

  if txn is not null then
    insert into pace_v2.ledger_entries(
      ledger_transaction_id,ledger_account_id,side,amount_cents,currency
    )
    values
      (txn,op_account,'credit',ca.operator_net_before_adjustments_cents,'USD'),
      (txn,commission_account,'credit',ca.pace_shuttles_commission_cents,'USD'),
      (txn,clearing_account,
       'debit',ca.operator_journey_value_cents,'USD');
  end if;

  perform pace_v2.apply_operator_liabilities_to_settlement(sid);

  return sid;
end;
$function$;

CREATE OR REPLACE FUNCTION pace_v2.captain_complete_journey(p_captain_assignment_id uuid, p_completed_normally boolean DEFAULT true, p_captain_notes text DEFAULT NULL::text, p_incident_flag boolean DEFAULT false, p_incident_summary text DEFAULT NULL::text)
 RETURNS TABLE(voyage_log_id uuid, actual_arrival_ts timestamp with time zone, actual_arrival_local timestamp without time zone, trip_timezone text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pace_v2', 'public'
AS $function$
declare
  v_log_id uuid;
  v_departure_id uuid;
  v_allocation_id uuid;
begin
  if auth.uid() is null or not exists (
    select 1 from pace_v2.captain_assignments ca
    join pace_v2.captains c on c.id=ca.captain_id
    where ca.id=p_captain_assignment_id and ca.active
      and c.auth_user_id=auth.uid() and c.active
  ) then
    raise exception 'Active captain assignment required';
  end if;
  v_log_id := pace_v2.ensure_voyage_log(p_captain_assignment_id);

  if not exists (
    select 1
    from pace_v2.voyage_logs vl
    where vl.id=v_log_id
      and vl.actual_departure_ts is not null
  ) then
    raise exception 'Journey cannot be completed before it has been started';
  end if;

  select ca.confirmed_allocation_id, coa.departure_id
    into v_allocation_id, v_departure_id
  from pace_v2.captain_assignments ca
  join pace_v2.confirmed_allocations coa
    on coa.id=ca.confirmed_allocation_id
  where ca.id=p_captain_assignment_id
    and ca.active=true;

  if v_allocation_id is null then
    raise exception 'No active captain assignment found';
  end if;

  update pace_v2.voyage_logs vl
  set
    actual_departure_ts=coalesce((
      select min(operation.started_at) from pace_v2.captain_leg_operations operation
      join pace_v2.departures leg on leg.id=operation.departure_id
      where operation.confirmed_allocation_id=v_allocation_id and leg.leg_number=1
    ),vl.actual_departure_ts),
    actual_arrival_ts=coalesce((
      select operation.ended_at from pace_v2.captain_leg_operations operation
      join pace_v2.departures leg on leg.id=operation.departure_id
      where operation.confirmed_allocation_id=v_allocation_id and leg.leg_number=2
        and operation.finalization_authorized and operation.ended_at is not null
    ),vl.actual_arrival_ts,now()),
    completed_normally=p_completed_normally,
    captain_notes=coalesce(p_captain_notes,vl.captain_notes),
    incident_flag=p_incident_flag,
    incident_summary=case
      when p_incident_flag
        then coalesce(p_incident_summary,vl.incident_summary)
      else vl.incident_summary
    end
  where vl.id=v_log_id;

  update pace_v2.confirmed_allocations ca
  set
    status='completed',
    completed_at=coalesce(ca.completed_at,now())
  where ca.id=v_allocation_id
    and ca.status='confirmed';

  update pace_v2.bookings b
  set
    status='completed',
    updated_at=now()
  where b.departure_id=v_departure_id
    and b.status='confirmed'
    and exists (
      select 1
      from pace_v2.booking_allocations ba
      where ba.booking_id=b.id
        and ba.vehicle_id=(
          select ca2.vehicle_id
          from pace_v2.confirmed_allocations ca2
          where ca2.id=v_allocation_id
        )
        and ba.status='confirmed'
    );

  if not exists (
    select 1
    from pace_v2.confirmed_allocations ca
    where ca.departure_id=v_departure_id
      and ca.status='confirmed'
  ) then
    update pace_v2.departures d
    set
      status='completed',
      completed_at=coalesce(d.completed_at,now()),
      updated_at=now()
    where d.id=v_departure_id
      and d.status in ('active','confirmed');
  end if;

  insert into pace_v2.quality_evidence(
    departure_id,
    confirmed_allocation_id,
    operator_id,
    vehicle_id,
    captain_id,
    evidence_type,
    attribution,
    evidence_payload,
    source_table,
    source_id,
    occurred_at
  )
  select
    d.id,
    coa.id,
    coa.operator_id,
    coa.vehicle_id,
    ca.captain_id,
    'journey_completed',
    'operator',
    jsonb_build_object(
      'actual_departure_ts',vl.actual_departure_ts,
      'actual_arrival_ts',vl.actual_arrival_ts,
      'trip_timezone',d.trip_timezone,
      'actual_departure_local',
        vl.actual_departure_ts at time zone d.trip_timezone,
      'actual_arrival_local',
        vl.actual_arrival_ts at time zone d.trip_timezone,
      'completed_normally',vl.completed_normally,
      'incident_flag',vl.incident_flag,
      'incident_summary',vl.incident_summary
    ),
    'voyage_logs',
    vl.id,
    vl.actual_arrival_ts
  from pace_v2.voyage_logs vl
  join pace_v2.confirmed_allocations coa
    on coa.id=vl.confirmed_allocation_id
  join pace_v2.departures d
    on d.id=coa.departure_id
  join pace_v2.captain_assignments ca
    on ca.id=p_captain_assignment_id
  where vl.id=v_log_id
  on conflict do nothing;

  -- Pending accrual only; approval and payment remain separate admin actions.
  perform pace_v2.create_settlement_for_allocation(v_allocation_id,
    (select vl.actual_arrival_ts from pace_v2.voyage_logs vl where vl.id=v_log_id));

  return query
  select
    vl.id,
    vl.actual_arrival_ts,
    vl.actual_arrival_ts at time zone d.trip_timezone,
    d.trip_timezone
  from pace_v2.voyage_logs vl
  join pace_v2.confirmed_allocations coa
    on coa.id=vl.confirmed_allocation_id
  join pace_v2.departures d
    on d.id=coa.departure_id
  where vl.id=v_log_id;
end;
$function$;

commit;
