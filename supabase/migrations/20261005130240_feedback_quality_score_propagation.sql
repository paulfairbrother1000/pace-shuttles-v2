-- Canonical V2 weighted evidence, automatic score refresh, legacy compatibility.
CREATE OR REPLACE FUNCTION pace_v2.capture_customer_feedback_quality_evidence()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pace_v2', 'public'
AS $function$
declare
  cfg pace_v2.quality_score_config%rowtype;
  nps_effect numeric := 0;
  rating_effect numeric := 0;
begin
  -- Version-two submission writes one canonical set after all dimensions exist.
  if new.feedback_schema_version>=2 and new.booking_experience_rating is not null
     and new.captain_rating is not null then return new; end if;
  select *
  into cfg
  from pace_v2.quality_score_config
  where active=true
  order by
    case when config_name='default' then 0 else 1 end,
    created_at
  limit 1;

  if new.pace_shuttles_nps_score is not null then
    nps_effect :=
      case
        when new.pace_shuttles_nps_score >= 9
          then cfg.nps_promoter_effect
        when new.pace_shuttles_nps_score >= 7
          then cfg.nps_passive_effect
        else cfg.nps_detractor_effect
      end;

    insert into pace_v2.quality_evidence(
      departure_id,
      confirmed_allocation_id,
      operator_id,
      vehicle_id,
      booking_id,
      evidence_type,
      attribution,
      score_effect,
      evidence_payload,
      source_table,
      source_id,
      occurred_at
    )
    values(
      new.departure_id,
      new.confirmed_allocation_id,
      new.operator_id,
      new.vehicle_id,
      new.booking_id,
      'customer_nps',
      new.attribution::text,
      case
        when new.attribution::text='operator' then nps_effect
        else 0
      end,
      jsonb_build_object(
        'pace_shuttles_nps_score',new.pace_shuttles_nps_score,
        'category',
          case
            when new.pace_shuttles_nps_score >= 9 then 'promoter'
            when new.pace_shuttles_nps_score >= 7 then 'passive'
            else 'detractor'
          end,
        'raw_effect',nps_effect,
        'comment',new.comment
      ),
      'customer_feedback',
      new.id,
      new.created_at
    )
    on conflict do nothing;
  end if;

  if new.operator_rating is not null then
    rating_effect :=
      case new.operator_rating
        when 5 then cfg.rating_5_effect
        when 4 then cfg.rating_4_effect
        when 3 then cfg.rating_3_effect
        when 2 then cfg.rating_2_effect
        when 1 then cfg.rating_1_effect
      end;

    insert into pace_v2.quality_evidence(
      departure_id,
      confirmed_allocation_id,
      operator_id,
      vehicle_id,
      booking_id,
      evidence_type,
      attribution,
      score_effect,
      evidence_payload,
      source_table,
      source_id,
      occurred_at
    )
    values(
      new.departure_id,
      new.confirmed_allocation_id,
      new.operator_id,
      new.vehicle_id,
      new.booking_id,
      'operator_journey_rating',
      new.attribution::text,
      case
        when new.attribution::text='operator' then rating_effect
        else 0
      end,
      jsonb_build_object(
        'operator_rating',new.operator_rating,
        'raw_effect',rating_effect,
        'comment',new.comment
      ),
      'customer_feedback',
      new.id,
      new.created_at
    )
    on conflict do nothing;
  end if;

  return new;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.v2_customer_submit_feedback(p_booking_id uuid, p_nps integer, p_operator_rating integer, p_comment text DEFAULT NULL::text, p_attribution text DEFAULT 'unassigned'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pace_v2', 'auth'
AS $function$
declare v_departure uuid; v_operator uuid; v_vehicle uuid; v_ca uuid; v_id uuid;
begin
 if p_nps<0 or p_nps>10 then raise exception 'NPS must be between 0 and 10'; end if;
 if p_operator_rating<1 or p_operator_rating>5 then raise exception 'operator rating must be between 1 and 5'; end if;
 if p_attribution not in ('operator','pace_shuttles','customer','external','unassigned') then raise exception 'invalid attribution'; end if;
 select b.departure_id into v_departure from pace_v2.bookings b join pace_v2.orders o on o.id=b.order_id where b.id=p_booking_id and o.customer_user_id=auth.uid();
 if v_departure is null then raise exception 'booking not found for signed-in customer'; end if;
 if not exists(select 1 from pace_v2.departures d where d.id=v_departure and d.status='completed') then raise exception 'feedback is available after the journey is completed'; end if;
 select ca.id,ca.operator_id,ca.vehicle_id into v_ca,v_operator,v_vehicle
 from pace_v2.booking_allocations ba
 join pace_v2.confirmed_allocations ca on ca.departure_id=ba.departure_id and ca.vehicle_id=ba.vehicle_id
 where ba.booking_id=p_booking_id and ba.status='confirmed'::pace_v2.allocation_status
 order by ca.confirmed_at desc limit 1;
 if v_ca is null then raise exception 'confirmed allocation not found for booking'; end if;
 if exists(select 1 from pace_v2.customer_feedback where booking_id=p_booking_id) then raise exception 'feedback already submitted for this booking'; end if;
 perform 1 from pace_v2.operators where id=v_operator for update;
 insert into pace_v2.customer_feedback(booking_id,departure_id,operator_id,pace_shuttles_nps_score,operator_rating,comment,attribution,confirmed_allocation_id,vehicle_id,feedback_schema_version)
 values(p_booking_id,v_departure,v_operator,p_nps,p_operator_rating,nullif(trim(coalesce(p_comment,'')),''),p_attribution::pace_v2.attribution_type,v_ca,v_vehicle,1)
 returning id into v_id;
 perform pace_v2.refresh_operator_quality_score(v_operator,clock_timestamp());
 return v_id;
end $function$
;
CREATE OR REPLACE FUNCTION public.v2_customer_submit_feedback(p_booking_id uuid, p_booking_experience_rating integer, p_nps integer, p_operator_rating integer, p_captain_rating integer, p_pickup_rating integer, p_destination_rating integer, p_went_well text, p_could_improve text, p_testimonial_consent boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pace_v2', 'auth'
AS $function$
declare
  v_user_id uuid:=auth.uid(); v_row record; v_feedback_id uuid; v_operator_weight numeric; v_captain_weight numeric; v_decay integer;
  operator_rating_effect numeric; captain_rating_effect numeric; weighted_rating numeric; v_low_dimensions jsonb:='[]'::jsonb;
begin
  if v_user_id is null then raise exception 'authentication required'; end if;
  if not pace_v2.is_active_paid_journey_booking(p_booking_id,v_user_id) then raise exception 'eligible paid booking owned by the authenticated customer required'; end if;
  if p_booking_experience_rating is null or p_nps is null or p_operator_rating is null or p_captain_rating is null or p_pickup_rating is null or p_destination_rating is null then raise exception 'all ratings are required'; end if;
  if p_booking_experience_rating not between 1 and 5 or p_operator_rating not between 1 and 5 or p_captain_rating not between 1 and 5 or p_pickup_rating not between 1 and 5 or p_destination_rating not between 1 and 5 then raise exception 'ratings must be integers from 1 to 5'; end if;
  if p_nps not between 0 and 10 then raise exception 'NPS must be an integer from 0 to 10'; end if;
  if p_testimonial_consent is null then raise exception 'testimonial consent must be explicit'; end if;
  select ca.id confirmed_allocation_id,ca.operator_id,ca.vehicle_id,d.id departure_id,coalesce(d.completed_at,d.actual_arrival_ts) as actual_arrival_ts,r.pickup_id,r.destination_id,a.captain_id
  into strict v_row
  from pace_v2.bookings b
  join pace_v2.booking_allocations ba on ba.booking_id=b.id
  join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status='completed'
  join pace_v2.departures d on d.id=ca.departure_id
  join pace_v2.routes r on r.id=d.route_id
  join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id
  where b.id=p_booking_id and d.status='completed' and coalesce(d.completed_at,d.actual_arrival_ts) is not null and coalesce(d.completed_at,d.actual_arrival_ts)<=now()
    and (select count(*) from pace_v2.captain_assignments a2 where a2.confirmed_allocation_id=ca.id and a2.active)=1;
  select operator_rating_weight,captain_rating_weight,evidence_decay_half_life_days into strict v_operator_weight,v_captain_weight,v_decay from pace_v2.quality_configuration where config_key='journey_feedback';
  operator_rating_effect:=(p_operator_rating-3)::numeric/2;
  captain_rating_effect:=(p_captain_rating-3)::numeric/2;
  weighted_rating := (operator_rating_effect * v_operator_weight) + (captain_rating_effect * v_captain_weight);

  perform 1 from pace_v2.operators where id=v_row.operator_id for update;
  insert into pace_v2.customer_feedback(booking_id,departure_id,confirmed_allocation_id,operator_id,vehicle_id,captain_id,pickup_id,destination_id,submitted_by,booking_experience_rating,pace_shuttles_nps_score,operator_rating,captain_rating,pickup_rating,destination_rating,went_well,could_improve,testimonial_consent,feedback_schema_version)
  values(p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,v_row.operator_id,v_row.vehicle_id,v_row.captain_id,v_row.pickup_id,v_row.destination_id,v_user_id,p_booking_experience_rating,p_nps,p_operator_rating,p_captain_rating,p_pickup_rating,p_destination_rating,nullif(trim(coalesce(p_went_well,'')),''),nullif(trim(coalesce(p_could_improve,'')),''),p_testimonial_consent,2)
  returning id into v_feedback_id;

  insert into pace_v2.platform_quality_history(feedback_id,booking_id,dimension,rating,rating_effect,operator_score_effect,occurred_at) values
    (v_feedback_id,p_booking_id,'booking_experience',p_booking_experience_rating,(p_booking_experience_rating-3)::numeric/2,0,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,'pace_shuttles_nps',p_nps,case when p_nps<=6 then -1 when p_nps<=8 then 0 else 1 end,0,v_row.actual_arrival_ts);
  insert into pace_v2.captain_quality_history(feedback_id,booking_id,departure_id,captain_id,rating,rating_effect,occurred_at) values(v_feedback_id,p_booking_id,v_row.departure_id,v_row.captain_id,p_captain_rating,captain_rating_effect,v_row.actual_arrival_ts);
  insert into pace_v2.pickup_quality_history(feedback_id,booking_id,departure_id,pickup_id,rating,rating_effect,occurred_at) values(v_feedback_id,p_booking_id,v_row.departure_id,v_row.pickup_id,p_pickup_rating,(p_pickup_rating-3)::numeric/2,v_row.actual_arrival_ts);
  insert into pace_v2.destination_quality_history(feedback_id,booking_id,departure_id,destination_id,rating,rating_effect,occurred_at) values(v_feedback_id,p_booking_id,v_row.departure_id,v_row.destination_id,p_destination_rating,(p_destination_rating-3)::numeric/2,v_row.actual_arrival_ts);

  insert into pace_v2.quality_evidence(feedback_id,booking_id,departure_id,confirmed_allocation_id,operator_id,vehicle_id,captain_id,pickup_id,destination_id,evidence_type,attribution,dimension,rating,rating_effect,operator_score_effect,evidence_weight,decay_half_life_days,occurred_at) values
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,null,null,null,null,null,'customer_feedback','pace_shuttles','booking_experience',p_booking_experience_rating,(p_booking_experience_rating-3)::numeric/2,0,1,v_decay,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,null,null,null,null,null,'customer_feedback','pace_shuttles','pace_shuttles_nps',p_nps,case when p_nps<=6 then -1 when p_nps<=8 then 0 else 1 end,0,1,v_decay,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,v_row.operator_id,v_row.vehicle_id,v_row.captain_id,null,null,'customer_feedback','operator','operator_journey',p_operator_rating,operator_rating_effect,weighted_rating,1,v_decay,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,v_row.operator_id,v_row.vehicle_id,v_row.captain_id,null,null,'customer_feedback','operator','captain',p_captain_rating,captain_rating_effect,0,1,v_decay,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,null,null,null,v_row.pickup_id,null,'customer_feedback','pace_shuttles','pickup',p_pickup_rating,(p_pickup_rating-3)::numeric/2,0,1,v_decay,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,null,null,null,null,v_row.destination_id,'customer_feedback','pace_shuttles','destination',p_destination_rating,(p_destination_rating-3)::numeric/2,0,1,v_decay,v_row.actual_arrival_ts);

  if p_booking_experience_rating<=2 then v_low_dimensions:=v_low_dimensions||'"booking_experience"'::jsonb; end if;
  if p_nps<=2 then v_low_dimensions:=v_low_dimensions||'"pace_shuttles_nps"'::jsonb; end if;
  if p_operator_rating<=2 then v_low_dimensions:=v_low_dimensions||'"operator_journey"'::jsonb; end if;
  if p_captain_rating<=2 then v_low_dimensions:=v_low_dimensions||'"captain"'::jsonb; end if;
  if p_pickup_rating<=2 then v_low_dimensions:=v_low_dimensions||'"pickup"'::jsonb; end if;
  if p_destination_rating<=2 then v_low_dimensions:=v_low_dimensions||'"destination"'::jsonb; end if;
  if jsonb_array_length(v_low_dimensions)>0 then
    insert into pace_v2.operational_alerts(exception_key,exception_type,severity,confirmed_allocation_id,booking_id,departure_id,details)
    values('journey_feedback_attribution_review:'||v_feedback_id::text,'journey_feedback_attribution_review','high',v_row.confirmed_allocation_id,p_booking_id,v_row.departure_id,jsonb_build_object('feedback_id',v_feedback_id,'low_dimensions',v_low_dimensions,'operator_score_effect',weighted_rating));
  end if;
  perform pace_v2.refresh_operator_quality_score(v_row.operator_id,clock_timestamp());
  return v_feedback_id;
exception when no_data_found then raise exception 'completed confirmed journey with one captain required';
end;
$function$
;
CREATE OR REPLACE FUNCTION pace_v2.calculate_operator_quality_score(p_operator_id uuid,p_as_of timestamptz DEFAULT now())
RETURNS TABLE(quality_score numeric,baseline_score numeric,weighted_effect numeric,evidence_count integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'pace_v2','public'
AS $function$
with cfg as (
 select * from pace_v2.quality_score_config where active
 order by case when config_name='default' then 0 else 1 end,created_at limit 1
), evidence as (
 select
  case when qe.evidence_type='customer_feedback' and qe.dimension='operator_journey'
    then qe.operator_score_effect*qe.evidence_weight
    when cf.reviewed_at is not null and cf.attribution::text='operator'
    then coalesce((qe.evidence_payload->>'raw_effect')::numeric,qe.score_effect)
    else qe.score_effect end as score_effect,
  power(0.5::numeric,(extract(epoch from(p_as_of-qe.occurred_at))/86400.0)/
    coalesce(qe.decay_half_life_days,cfg.half_life_days)) as decay_factor
 from pace_v2.quality_evidence qe cross join cfg
 left join pace_v2.customer_feedback cf on cf.id=coalesce(qe.feedback_id,
   case when qe.source_table='customer_feedback' then qe.source_id end)
 where qe.operator_id=p_operator_id
   and qe.occurred_at<=p_as_of
   and qe.occurred_at>=p_as_of-make_interval(days=>cfg.rolling_window_days)
   and (
     (qe.evidence_type='customer_feedback' and qe.dimension='operator_journey'
       and qe.attribution='operator'
       and (cf.reviewed_at is null or cf.attribution::text='operator'))
     or
     (qe.feedback_id is null and qe.evidence_type<>'customer_nps'
       and case when cf.reviewed_at is not null then cf.attribution::text
         else qe.attribution end='operator'
       and not exists(
         select 1 from pace_v2.quality_evidence canonical
         where canonical.feedback_id=cf.id
           and canonical.evidence_type='customer_feedback'
           and canonical.dimension='operator_journey'
       ))
   )
), agg as (
 select coalesce(sum(score_effect*decay_factor),0)::numeric weighted_effect,
   count(*)::integer evidence_count from evidence
)
select greatest(cfg.min_score,least(cfg.max_score,cfg.baseline_score+agg.weighted_effect))::numeric,
 cfg.baseline_score::numeric,agg.weighted_effect,agg.evidence_count from cfg cross join agg;
$function$;
CREATE OR REPLACE FUNCTION pace_v2.refresh_operator_quality_score(p_operator_id uuid, p_as_of timestamp with time zone DEFAULT now())
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pace_v2', 'public'
AS $function$
declare
  calc record;
  cfg record;
begin
  -- Serialize before calculating, so a waiter sees the committed evidence
  -- of the prior refresh instead of overwriting it with a stale total.
  perform 1 from pace_v2.operators where id=p_operator_id for update;
  select *
  into calc
  from pace_v2.calculate_operator_quality_score(p_operator_id,p_as_of);

  select *
  into cfg
  from pace_v2.quality_score_config
  where active=true
  order by case when config_name='default' then 0 else 1 end,created_at
  limit 1;

  update pace_v2.operators o
  set quality_score=calc.quality_score,quality_score_updated_at=p_as_of
  where o.id=p_operator_id;

  insert into pace_v2.quality_score_history(
    operator_id,quality_score,baseline_score,weighted_effect,
    evidence_count,rolling_window_days,half_life_days,calculated_at
  )
  values(
    p_operator_id,
    calc.quality_score,
    calc.baseline_score,
    calc.weighted_effect,
    calc.evidence_count,
    cfg.rolling_window_days,
    cfg.half_life_days,
    p_as_of
  );

  return calc.quality_score;
end;
$function$
;
