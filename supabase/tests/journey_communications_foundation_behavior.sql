begin;

do $$
declare
  v_allocation_id uuid;
  v_assignment_id uuid;
  v_captain_id uuid;
  v_captain_vehicle_type_id uuid;
  v_departure_id uuid;
  v_operator_id uuid;
  v_vehicle_id uuid;
  v_other_operator_id uuid;
  v_other_vehicle_id uuid;
  v_other_allocation_id uuid;
  v_booking_id uuid;
  v_booking_allocation_id uuid;
  v_conversation_id uuid;
  v_rejected boolean;
begin
  select ca.id,a.id,c.id,cvt.id,ca.departure_id,ca.operator_id,ca.vehicle_id
    into v_allocation_id,v_assignment_id,v_captain_id,v_captain_vehicle_type_id,
      v_departure_id,v_operator_id,v_vehicle_id
  from pace_v2.confirmed_allocations ca
  join pace_v2.captain_assignments a
    on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains c on c.id=a.captain_id and c.active and c.operator_id=ca.operator_id
  join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
  join pace_v2.captain_vehicle_types cvt
    on cvt.captain_id=c.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
  where ca.status='confirmed'
    and (
      select count(distinct a2.id)
      from pace_v2.captain_assignments a2
      join pace_v2.captains c2 on c2.id=a2.captain_id and c2.active and c2.operator_id=ca.operator_id
      join pace_v2.captain_vehicle_types cvt2 on cvt2.captain_id=c2.id and cvt2.vehicle_type_id=v.vehicle_type_id and cvt2.active
      where a2.confirmed_allocation_id=ca.id and a2.active
    )=1
    and (
      select count(*) from pace_v2.captain_vehicle_types cvt2
      where cvt2.captain_id=c.id and cvt2.vehicle_type_id=v.vehicle_type_id and cvt2.active
    )=1
  order by ca.id,a.id
  limit 1;

  if v_allocation_id is null then
    raise exception 'fixture: source allocation with exactly one final eligible captain support required';
  end if;

  select ba.id,ba.booking_id into v_booking_allocation_id,v_booking_id
  from pace_v2.booking_allocations ba
  join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id
  where ca.id=v_allocation_id
  order by ba.id limit 1;
  if v_booking_allocation_id is null then raise exception 'fixture: booking allocation for confirmed allocation required'; end if;
  insert into pace_v2.journey_conversations(booking_id,confirmed_allocation_id)
  values(v_booking_id,v_allocation_id) returning id into v_conversation_id;
  v_rejected:=false;
  begin
    delete from pace_v2.booking_allocations where id=v_booking_allocation_id;
    set constraints all immediate;
  exception when others then
    if sqlerrm ilike '%orphan a journey conversation%' then v_rejected:=true; else raise; end if;
  end;
  if not v_rejected then raise exception 'booking allocation deletion orphaned a journey conversation'; end if;

  update pace_v2.departures set
    scheduled_departure_ts='2030-01-02 12:00:00+00',
    scheduled_arrival_ts='2030-01-02 14:00:00+00',
    actual_arrival_ts=null
  where id=v_departure_id;

  if pace_v2.journey_message_opens_at(v_allocation_id) <> '2030-01-01 12:00:00+00'::timestamptz
    or pace_v2.journey_message_closes_at(v_allocation_id) <> '2030-01-03 02:00:00+00'::timestamptz
    or pace_v2.is_journey_message_window_open(v_allocation_id,'2030-01-01 11:59:59+00')
    or not pace_v2.is_journey_message_window_open(v_allocation_id,'2030-01-01 12:00:00+00')
    or pace_v2.is_journey_message_window_open(v_allocation_id,'2030-01-03 02:00:00+00') then
    raise exception 'T-24 and missing-completion message window boundaries are incorrect';
  end if;

  update pace_v2.departures set actual_arrival_ts='2030-01-02 15:30:00+00' where id=v_departure_id;
  if pace_v2.journey_message_closes_at(v_allocation_id) <> '2030-01-02 19:30:00+00'::timestamptz
    or not pace_v2.is_journey_message_window_open(v_allocation_id,'2030-01-02 19:29:59+00')
    or pace_v2.is_journey_message_window_open(v_allocation_id,'2030-01-02 19:30:00+00') then
    raise exception 'actual-arrival message window boundary is incorrect';
  end if;

  v_rejected:=false;
  begin
    update pace_v2.captain_assignments set active=false where id=v_assignment_id;
    set constraints all immediate;
  exception when others then
    if sqlerrm ilike '%active eligible assigned captain%' then v_rejected:=true; else raise; end if;
  end;
  if not v_rejected then raise exception 'inactive assignment was accepted for a confirmed allocation'; end if;

  v_rejected:=false;
  begin
    update pace_v2.captains set active=false where id=v_captain_id;
    set constraints all immediate;
  exception when others then
    if sqlerrm ilike '%active eligible assigned captain%' then v_rejected:=true; else raise; end if;
  end;
  if not v_rejected then raise exception 'inactive captain was accepted for a confirmed allocation'; end if;

  v_rejected:=false;
  begin
    update pace_v2.captain_vehicle_types set active=false where id=v_captain_vehicle_type_id;
    set constraints all immediate;
  exception when others then
    if sqlerrm ilike '%active eligible assigned captain%' then v_rejected:=true; else raise; end if;
  end;
  if not v_rejected then raise exception 'inactive captain vehicle type was accepted for a confirmed allocation'; end if;

  v_rejected:=false;
  begin
    delete from pace_v2.captain_vehicle_types where id=v_captain_vehicle_type_id;
    set constraints all immediate;
  exception when others then
    if sqlerrm ilike '%active eligible assigned captain%' then v_rejected:=true; else raise; end if;
  end;
  if not v_rejected then raise exception 'deleted captain vehicle type was accepted for a confirmed allocation'; end if;

  select o.id into v_other_operator_id from pace_v2.operators o where o.id<>v_operator_id order by o.id limit 1;
  if v_other_operator_id is null then raise exception 'fixture: second operator required'; end if;
  v_rejected:=false;
  begin
    update pace_v2.confirmed_allocations set operator_id=v_other_operator_id where id=v_allocation_id;
    set constraints all immediate;
  exception when others then
    if sqlerrm ilike '%active eligible assigned captain%' then v_rejected:=true; else raise; end if;
  end;
  if not v_rejected then raise exception 'operator-mismatched captain was accepted'; end if;

  select v.id into v_other_vehicle_id
  from pace_v2.vehicles v
  join pace_v2.vehicles current_vehicle on current_vehicle.id=v_vehicle_id
  where v.operator_id=v_operator_id and v.active and v.vehicle_type_id<>current_vehicle.vehicle_type_id
  order by v.id limit 1;
  if v_other_vehicle_id is null then raise exception 'fixture: second vehicle type for allocation operator required'; end if;
  v_rejected:=false;
  begin
    update pace_v2.confirmed_allocations set vehicle_id=v_other_vehicle_id where id=v_allocation_id;
    set constraints all immediate;
  exception when others then
    if sqlerrm ilike '%active eligible assigned captain%' then v_rejected:=true; else raise; end if;
  end;
  if not v_rejected then raise exception 'vehicle-type-mismatched captain was accepted'; end if;

  select ca.id into v_other_allocation_id
  from pace_v2.confirmed_allocations ca
  join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains c on c.id=a.captain_id and c.active and c.operator_id=ca.operator_id
  join pace_v2.vehicles v on v.id=ca.vehicle_id and v.active
  join pace_v2.captain_vehicle_types cvt on cvt.captain_id=c.id and cvt.vehicle_type_id=v.vehicle_type_id and cvt.active
  where ca.status='confirmed' and ca.id<>v_allocation_id
    and exists(
      select 1 from pace_v2.captain_assignments a2
      join pace_v2.captains c2 on c2.id=a2.captain_id and c2.active and c2.operator_id=ca.operator_id
      join pace_v2.captain_vehicle_types cvt2 on cvt2.captain_id=c2.id and cvt2.vehicle_type_id=v.vehicle_type_id and cvt2.active
      where a2.confirmed_allocation_id=ca.id and a2.active and a2.id<>v_assignment_id
    )
  order by ca.id limit 1;
  if v_other_allocation_id is null then raise exception 'fixture: independently eligible destination allocation required'; end if;
  v_rejected:=false;
  begin
    update pace_v2.captain_assignments set confirmed_allocation_id=v_other_allocation_id where id=v_assignment_id;
    set constraints all immediate;
  exception when others then
    if sqlerrm ilike '%active eligible assigned captain%' then v_rejected:=true; else raise; end if;
  end;
  if not v_rejected then raise exception 'moving the final assignment did not revalidate its former allocation'; end if;

  update pace_v2.confirmed_allocations set status='cancelled' where id=v_allocation_id;
  delete from pace_v2.captain_assignments where id=v_assignment_id;
  set constraints all immediate;
end $$;

rollback;
