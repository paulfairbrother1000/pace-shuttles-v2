-- Keep selling contiguous seats on the final eligible vehicle after it reaches
-- minimum. The two-vehicle discount remains locked until two minimums exist.
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
language plpgsql
security definer
set search_path = pace_v2, public
as $$
begin
  if p_party_size is null or p_party_size < 1 then
    raise exception 'Party size must be at least 1';
  end if;

  perform pace_v2.refresh_vehicle_considerations(p_departure_id,'live-progressive-v0.5');
  perform pace_v2.refresh_live_consideration_states(p_departure_id);

  return query
  with ordered as (
    select vc.id as consideration_id,vc.vehicle_id,vc.operator_id,
      v.name as vehicle_name,o.name as operator_name,vc.normal_min_seats,
      vc.max_seats,vc.assigned_seats,
      greatest(vc.max_seats-vc.assigned_seats,0) as remaining_capacity,
      vc.normal_base_seat_price_cents as normal_price,
      vc.quality_score_snapshot as quality_score,
      vc.post_min_discount_enabled as discount_enabled,
      vc.post_min_discount_bps as discount_bps,
      row_number() over(order by vc.normal_base_seat_price_cents asc,
        vc.quality_score_snapshot desc,vc.created_at asc,vc.id asc)::integer as seq,
      (vc.assigned_seats>=vc.normal_min_seats) as min_met
    from pace_v2.vehicle_considerations vc
    join pace_v2.vehicles v on v.id=vc.vehicle_id
    join pace_v2.operators o on o.id=vc.operator_id
    where vc.departure_id=p_departure_id
      and vc.status not in('withdrawn','discarded_t72','under_consideration','confirmed','replaced','cancelled')
  ),
  state as (
    select coalesce(count(*) filter(where min_met),0)::integer as min_met_count,
      coalesce(min(seq) filter(where not min_met),2147483647)::integer as frontier_seq
    from ordered
  ),
  target as (
    select min(o.seq)::integer as normal_target_seq
    from ordered o,state s
    where not o.min_met and o.seq>=s.frontier_seq
      and o.remaining_capacity>=p_party_size
  ),
  raw_candidates as (
    select o.*,
      case when s.min_met_count=0 then 'FILL_VEHICLE_1_MINIMUM'
        when s.min_met_count=1 then 'FILL_VEHICLE_2_MINIMUM'
        else 'NEXT_VEHICLE_NORMAL_MINIMUM' end::text as stage,
      false as use_discount,o.normal_price as offer_price
    from ordered o cross join state s cross join target t
    where t.normal_target_seq is not null and o.seq=t.normal_target_seq
      and o.remaining_capacity>=p_party_size

    union all

    select o.*,'LAST_VEHICLE_REMAINING_CAPACITY'::text as stage,
      false as use_discount,o.normal_price as offer_price
    from ordered o cross join state s cross join target t
    where t.normal_target_seq is null
      and s.min_met_count between 1 and 1
      and o.min_met and o.remaining_capacity>=p_party_size

    union all

    select o.*,'POST_TWO_MINIMUMS_COMPETITION'::text as stage,
      (o.discount_enabled and o.discount_bps>0) as use_discount,
      case when o.discount_enabled and o.discount_bps>0
        then ceil(o.normal_price::numeric*(10000-o.discount_bps)::numeric/10000)::integer
        else o.normal_price end as offer_price
    from ordered o cross join state s
    where s.min_met_count>=2 and o.min_met
      and o.remaining_capacity>=p_party_size
  ),
  deduped as (
    select distinct on(rc.consideration_id) rc.* from raw_candidates rc
    order by rc.consideration_id,rc.offer_price,rc.use_discount desc
  ),
  ranked as (
    select d.*,row_number() over(order by d.offer_price asc,d.quality_score desc,
      d.seq asc,d.consideration_id asc)::integer as offer_rank
    from deduped d
  )
  select r.offer_rank,r.consideration_id,r.vehicle_id,r.operator_id,
    r.vehicle_name,r.operator_name,r.seq,r.stage,r.assigned_seats,
    r.remaining_capacity,r.normal_min_seats,r.max_seats,r.min_met,
    ((select min_met_count from state)>=2),r.use_discount,
    r.normal_price,r.offer_price,r.discount_bps,r.quality_score
  from ranked r order by r.offer_rank;
end;
$$;
