-- Hold whole-party capacity while a customer completes Stripe Checkout.
-- Reservations expire after 30 minutes and never alter confirmed allocations.
create or replace function pace_v2.pending_reserved_seats(
  p_departure_id uuid,
  p_vehicle_id uuid
) returns integer
language sql
stable
security definer
set search_path = pace_v2, public
as $$
  select coalesce(sum(b.seats),0)::integer
  from pace_v2.bookings b
  join pace_v2.orders o on o.id=b.order_id and o.payment_status='pending'
  join pace_v2.quote_intents qi on qi.id=b.quote_intent_id
  where b.departure_id=p_departure_id
    and b.preliminary_vehicle_id=p_vehicle_id
    and b.status='pending_payment'
    and qi.expires_at>now()
    and coalesce((b.commercial_snapshot->>'reservation_expires_at')::timestamptz,qi.expires_at)>now();
$$;

create or replace function pace_v2.get_live_party_offer_candidates(
  p_departure_id uuid,
  p_party_size integer
)
returns table(
  candidate_rank integer, vehicle_consideration_id uuid, vehicle_id uuid,
  operator_id uuid, vehicle_name text, operator_name text, sequence_no integer,
  allocation_stage text, assigned_seats integer, remaining_capacity integer,
  normal_min_seats integer, max_seats integer, minimum_achieved boolean,
  discount_unlocked boolean, discount_applied boolean,
  normal_price_cents integer, offered_price_cents integer,
  post_min_discount_bps integer, quality_score numeric
)
language plpgsql security definer set search_path=pace_v2,public as $$
begin
  if p_party_size is null or p_party_size<1 then raise exception 'Party size must be at least 1'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_departure_id::text,0));
  perform pace_v2.refresh_vehicle_considerations(p_departure_id,'live-progressive-v0.6');
  perform pace_v2.refresh_live_consideration_states(p_departure_id);
  return query
  with ordered as (
    select vc.id consideration_id,vc.vehicle_id,vc.operator_id,v.name vehicle_name,o.name operator_name,
      vc.normal_min_seats,vc.max_seats,vc.assigned_seats,
      pace_v2.pending_reserved_seats(vc.departure_id,vc.vehicle_id) reserved_seats,
      greatest(vc.max_seats-vc.assigned_seats-pace_v2.pending_reserved_seats(vc.departure_id,vc.vehicle_id),0) remaining_capacity,
      vc.normal_base_seat_price_cents normal_price,vc.quality_score_snapshot quality_score,
      vc.post_min_discount_enabled discount_enabled,vc.post_min_discount_bps discount_bps,
      row_number() over(order by vc.normal_base_seat_price_cents,vc.quality_score_snapshot desc,vc.created_at,vc.id)::integer seq,
      (vc.assigned_seats>=vc.normal_min_seats) min_met
    from pace_v2.vehicle_considerations vc
    join pace_v2.vehicles v on v.id=vc.vehicle_id
    join pace_v2.operators o on o.id=vc.operator_id
    where vc.departure_id=p_departure_id
      and vc.status not in('withdrawn','discarded_t72','under_consideration','confirmed','replaced','cancelled')
  ), state as (
    select coalesce(count(*) filter(where min_met),0)::integer min_met_count,
      coalesce(min(seq) filter(where not min_met),2147483647)::integer frontier_seq from ordered
  ), target as (
    select min(o.seq)::integer normal_target_seq from ordered o,state s
    where not o.min_met and o.seq>=s.frontier_seq and o.remaining_capacity>=p_party_size
  ), raw_candidates as (
    select o.*,case when s.min_met_count=0 then 'FILL_VEHICLE_1_MINIMUM' when s.min_met_count=1 then 'FILL_VEHICLE_2_MINIMUM' else 'NEXT_VEHICLE_NORMAL_MINIMUM' end::text stage,
      false use_discount,o.normal_price offer_price
    from ordered o cross join state s cross join target t
    where t.normal_target_seq is not null and o.seq=t.normal_target_seq and o.remaining_capacity>=p_party_size
    union all
    select o.*,'LAST_VEHICLE_REMAINING_CAPACITY',false,o.normal_price
    from ordered o cross join state s cross join target t
    where t.normal_target_seq is null and s.min_met_count=1 and o.min_met and o.remaining_capacity>=p_party_size
    union all
    select o.*,'POST_TWO_MINIMUMS_COMPETITION',o.discount_enabled and o.discount_bps>0,
      case when o.discount_enabled and o.discount_bps>0 then ceil(o.normal_price::numeric*(10000-o.discount_bps)/10000)::integer else o.normal_price end
    from ordered o cross join state s where s.min_met_count>=2 and o.min_met and o.remaining_capacity>=p_party_size
  ), deduped as (
    select distinct on(consideration_id) * from raw_candidates order by consideration_id,offer_price,use_discount desc
  ), ranked as (
    select d.*,row_number() over(order by offer_price,quality_score desc,seq,consideration_id)::integer offer_rank from deduped d
  )
  select r.offer_rank,r.consideration_id,r.vehicle_id,r.operator_id,r.vehicle_name,r.operator_name,r.seq,r.stage,
    r.assigned_seats,r.remaining_capacity,r.normal_min_seats,r.max_seats,r.min_met,
    ((select min_met_count from state)>=2),r.use_discount,r.normal_price,r.offer_price,r.discount_bps,r.quality_score
  from ranked r order by r.offer_rank;
end $$;

drop function if exists public.v2_public_quote(uuid,integer);
create function public.v2_public_quote(p_departure_id uuid,p_party_size integer)
returns table(result_status text,departure_id uuid,route_id uuid,route_name text,pickup_name text,destination_name text,scheduled_departure_ts timestamptz,trip_timezone text,vehicle_consideration_id uuid,vehicle_id uuid,vehicle_name text,operator_id uuid,operator_name text,allocation_stage text,net_unit_price_cents integer,tax_cents integer,fee_cents integer,all_in_unit_price_cents integer,all_in_total_cents integer,currency text,discount_applied boolean,discount_bps integer,quality_score numeric,max_party_size integer,remaining_seats_total integer,quote_expires_at timestamptz)
language plpgsql security definer set search_path=public,pace_v2 as $$
declare offer record;dep record;tf record;v_tax integer:=0;v_fee integer:=0;v_tax_cents integer;v_fee_cents integer;v_allin integer;v_max integer;v_total integer;v_expiry timestamptz;
begin
 if p_party_size is null or p_party_size<1 or p_party_size>50 then raise exception 'Party size must be between 1 and 50';end if;
 select d.id,d.route_id,r.route_name,r.country_id,p.name pickup_name,dst.name destination_name,d.scheduled_departure_ts,d.trip_timezone,d.t24_ts into dep
 from pace_v2.departures d join pace_v2.routes r on r.id=d.route_id and r.is_active join pace_v2.countries c on c.id=r.country_id and c.active and c.customer_availability_paused is not true join pace_v2.pickup_points p on p.id=r.pickup_id and p.active join pace_v2.destinations dst on dst.id=r.destination_id and dst.active and dst.published_at is not null
 where d.id=p_departure_id and d.scheduled_departure_ts>now() and d.t24_ts>now() and d.status in('scheduled','selling','at_risk','under_consideration');
 if dep.id is null then raise exception 'Journey is not currently available for booking';end if;
 v_expiry:=least(dep.t24_ts,now()+interval '15 minutes');
 select * into offer from pace_v2.get_live_party_offer(p_departure_id,p_party_size);
 select coalesce(max(greatest(vc.max_seats-vc.assigned_seats-pace_v2.pending_reserved_seats(vc.departure_id,vc.vehicle_id),0)),0),
        coalesce(sum(greatest(vc.max_seats-vc.assigned_seats-pace_v2.pending_reserved_seats(vc.departure_id,vc.vehicle_id),0)),0)
 into v_max,v_total from pace_v2.vehicle_considerations vc where vc.departure_id=p_departure_id and vc.status not in('withdrawn','discarded_t72','under_consideration','confirmed','replaced','cancelled');
 if offer.result_status<>'offer' then return query select offer.result_status,dep.id,dep.route_id,dep.route_name,dep.pickup_name,dep.destination_name,dep.scheduled_departure_ts,dep.trip_timezone,offer.vehicle_consideration_id,offer.vehicle_id,offer.vehicle_name,offer.operator_id,offer.operator_name,offer.allocation_stage,coalesce(offer.offered_price_cents,0),0,0,0,0,'USD',coalesce(offer.discount_applied,false),coalesce(offer.discount_bps,0),offer.quality_score,v_max,v_total,v_expiry;return;end if;
 select ctf.tax_bps,ctf.customer_fee_bps into tf from pace_v2.country_tax_fees ctf where ctf.country_id=dep.country_id and ctf.effective_from<=now() and (ctf.effective_to is null or ctf.effective_to>now()) order by ctf.effective_from desc limit 1;
 v_tax:=coalesce(tf.tax_bps,0);v_fee:=coalesce(tf.customer_fee_bps,0);v_tax_cents:=round(offer.offered_price_cents*v_tax/10000.0);v_fee_cents:=round((offer.offered_price_cents+v_tax_cents)*v_fee/10000.0);v_allin:=offer.offered_price_cents+v_tax_cents+v_fee_cents;
 return query select 'offer',dep.id,dep.route_id,dep.route_name,dep.pickup_name,dep.destination_name,dep.scheduled_departure_ts,dep.trip_timezone,offer.vehicle_consideration_id,offer.vehicle_id,offer.vehicle_name,offer.operator_id,offer.operator_name,offer.allocation_stage,offer.offered_price_cents,v_tax_cents,v_fee_cents,v_allin,v_allin*p_party_size,'USD',offer.discount_applied,offer.discount_bps,offer.quality_score,v_max,v_total,v_expiry;
end $$;
grant execute on function public.v2_public_quote(uuid,integer) to anon,authenticated;

create or replace function public.v2_customer_commit_quote(p_quote_id uuid,p_customer_name text,p_customer_email text,p_lead_last_name text,p_passengers jsonb default '[]'::jsonb)
returns table(order_id uuid,booking_id uuid,departure_id uuid,route_name text,scheduled_departure_ts timestamptz,party_size integer,subtotal_cents integer,taxes_cents integer,fees_cents integer,total_cents integer,currency text,payment_status text)
language plpgsql security definer set search_path=public,pace_v2,auth as $$
declare qi pace_v2.quote_intents%rowtype;dep record;q record;v_order uuid;v_booking uuid;v_sub integer;v_tax integer;v_fees integer;v_total integer;item jsonb;v_net_unit integer;v_tax_unit integer;v_fee_unit integer;v_vehicle uuid;v_consideration uuid;v_reservation_expires timestamptz;
begin
 if auth.uid() is null then raise exception 'sign in required';end if;
 if trim(coalesce(p_customer_name,''))='' or trim(coalesce(p_customer_email,''))='' then raise exception 'customer name and email required';end if;
 select * into qi from pace_v2.quote_intents where id=p_quote_id for update;
 if not found or qi.expires_at<=now() then raise exception 'quote has expired; please choose the journey again';end if;
 if exists(select 1 from pace_v2.bookings where quote_intent_id=qi.id) then raise exception 'this quote has already been used';end if;
 perform pg_advisory_xact_lock(hashtextextended(qi.departure_id::text,0));
 select d.id,d.route_id,d.scheduled_departure_ts,d.t24_ts,r.route_name into dep from pace_v2.departures d join pace_v2.routes r on r.id=d.route_id and r.is_active join pace_v2.countries c on c.id=r.country_id and c.active and c.customer_availability_paused is not true where d.id=qi.departure_id and d.status not in('cancelled','completed') for share of c;
 if dep.id is null then raise exception 'journey is no longer available';end if;
 select * into q from pace_v2.get_live_party_offer(qi.departure_id,qi.party_size);
 v_consideration:=(qi.quote_snapshot->>'vehicle_consideration_id')::uuid;v_vehicle:=(qi.quote_snapshot->>'vehicle_id')::uuid;
 if q.result_status<>'offer' or q.vehicle_consideration_id is distinct from v_consideration or q.offered_price_cents is distinct from (qi.quote_snapshot->>'net_unit_price_cents')::integer then raise exception 'availability changed; please refresh the journey and try again';end if;
 v_net_unit:=coalesce((qi.quote_snapshot->>'net_unit_price_cents')::integer,qi.unit_price_cents);v_tax_unit:=coalesce((qi.quote_snapshot->>'tax_cents')::integer,0);v_fee_unit:=coalesce((qi.quote_snapshot->>'fee_cents')::integer,0);v_sub:=v_net_unit*qi.party_size;v_tax:=v_tax_unit*qi.party_size;v_fees:=v_fee_unit*qi.party_size;v_total:=qi.total_price_cents;v_reservation_expires:=least(dep.t24_ts,now()+interval '30 minutes');
 update pace_v2.quote_intents set expires_at=v_reservation_expires where id=qi.id;
 insert into pace_v2.orders(customer_user_id,customer_email,customer_name,currency,subtotal_cents,tax_rate_bps,customer_fee_rate_bps,taxes_cents,fees_cents,total_cents,payment_status) values(auth.uid(),lower(trim(p_customer_email)),trim(p_customer_name),'USD',v_sub,0,0,v_tax,v_fees,v_total,'pending') returning id into v_order;
 insert into pace_v2.bookings(order_id,departure_id,route_id,quote_intent_id,customer_name,lead_last_name,seats,status,currency,unit_price_cents,total_price_cents,preliminary_vehicle_id,commercial_snapshot) values(v_order,qi.departure_id,dep.route_id,qi.id,trim(p_customer_name),nullif(trim(coalesce(p_lead_last_name,'')),''),qi.party_size,'pending_payment','USD',v_net_unit,v_sub,v_vehicle,jsonb_build_object('payment_required_before_allocation',true,'reservation_expires_at',v_reservation_expires,'quote_snapshot',qi.quote_snapshot,'customer_all_in_total_cents',v_total,'taxes_cents',v_tax,'fees_cents',v_fees)) returning id into v_booking;
 if jsonb_typeof(p_passengers)='array' then for item in select * from jsonb_array_elements(p_passengers) loop if trim(coalesce(item->>'first_name',''))<>'' then insert into pace_v2.passengers(booking_id,first_name,last_name,age_group,email,phone,notes) values(v_booking,trim(item->>'first_name'),nullif(trim(coalesce(item->>'last_name','')),''),coalesce(nullif(trim(coalesce(item->>'age_group','')),''),'adult'),nullif(trim(coalesce(item->>'email','')),''),nullif(trim(coalesce(item->>'phone','')),''),nullif(trim(coalesce(item->>'notes','')),''));end if;end loop;end if;
 return query select v_order,v_booking,dep.id,dep.route_name,dep.scheduled_departure_ts,qi.party_size,v_sub,v_tax,v_fees,v_total,'USD','pending';
end $$;

notify pgrst,'reload schema';
