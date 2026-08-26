-- Scope every versioned vehicle offer to one recurring scheduled service while
-- retaining route_id as validated geographic provenance.

alter table pace_v2.vehicle_route_offers
  add column service_id uuid;

do $$
declare
  v_unresolved_count bigint;
begin
  select count(*) into v_unresolved_count
  from pace_v2.vehicle_route_offers vro
  where (
    select count(*)
    from pace_v2.services s
    where s.route_id=vro.route_id
  ) <> 1;

  if v_unresolved_count > 0 then
    raise exception 'Cannot backfill vehicle Route Offers: % offer(s) have routes mapping to zero or multiple services',v_unresolved_count;
  end if;

  update pace_v2.vehicle_route_offers vro
  set service_id=(
    select s.id
    from pace_v2.services s
    where s.route_id=vro.route_id
  );
end
$$;

alter table pace_v2.vehicle_route_offers
  add constraint vehicle_route_offers_service_id_fkey
  foreign key (service_id) references pace_v2.services(id);

alter table pace_v2.vehicle_route_offers
  alter column service_id set not null;

create or replace function pace_v2.validate_vehicle_route_offer_service()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_service_route_id uuid;
begin
  select s.route_id into v_service_route_id
  from pace_v2.services s
  where s.id=new.service_id
  for share;

  if v_service_route_id is null then
    raise exception 'Route Offer service does not exist';
  end if;
  if new.route_id is distinct from v_service_route_id then
    raise exception 'Route Offer route does not match selected service';
  end if;
  return new;
end;
$$;

revoke all on function pace_v2.validate_vehicle_route_offer_service() from public, anon, authenticated;

create or replace function pace_v2.prevent_offered_service_route_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.route_id is distinct from old.route_id and exists (
    select 1
    from pace_v2.vehicle_route_offers vro
    where vro.service_id=old.id
  ) then
    raise exception 'Cannot change the route of a service with vehicle Route Offers';
  end if;
  return new;
end;
$$;

revoke all on function pace_v2.prevent_offered_service_route_change() from public, anon, authenticated;

drop trigger if exists services_protect_offered_route on pace_v2.services;
create trigger services_protect_offered_route
before update of route_id on pace_v2.services
for each row execute function pace_v2.prevent_offered_service_route_change();

drop trigger if exists vehicle_route_offers_validate_service on pace_v2.vehicle_route_offers;
create trigger vehicle_route_offers_validate_service
before insert or update of service_id,route_id on pace_v2.vehicle_route_offers
for each row execute function pace_v2.validate_vehicle_route_offer_service();

drop index if exists pace_v2.vehicle_route_offers_one_current_per_vehicle_route;
create unique index vehicle_route_offers_one_current_per_vehicle_service
  on pace_v2.vehicle_route_offers(vehicle_id,service_id)
  where effective_to is null;

drop function public.v2_operator_load_vehicle_editor_routes();
create function public.v2_operator_load_vehicle_editor_routes()
returns table(
  operator_id uuid,route_id uuid,route_name text,
  service_id uuid,days_of_week smallint[],departure_time time,timezone text,
  vehicle_type_id uuid,country_id uuid,locality_id uuid
)
language sql
stable
security definer
set search_path = ''
as $$
  select er.operator_id,er.route_id,er.route_name,
    s.id,s.days_of_week,s.departure_time,s.timezone,
    er.vehicle_type_id,er.country_id,er.locality_id
  from public.v2_operator_vehicle_editor_routes er
  join pace_v2.services s on s.route_id=er.route_id and s.active
  where auth.uid() is not null
  order by er.route_name,s.days_of_week,s.departure_time;
$$;

revoke all on function public.v2_operator_load_vehicle_editor_routes() from public, anon, authenticated;
grant execute on function public.v2_operator_load_vehicle_editor_routes() to authenticated;

drop function public.v2_operator_load_vehicle_editor_offers();
create function public.v2_operator_load_vehicle_editor_offers()
returns table(
  offer_id uuid,operator_id uuid,vehicle_id uuid,route_id uuid,route_name text,
  service_id uuid,service_days_of_week smallint[],service_departure_time time,service_timezone text,
  preferred_captain_id uuid,preferred_captain_name text,preferred boolean,active boolean,
  min_seats integer,max_seats integer,min_revenue_cents integer,
  min_value_threshold_ratio numeric,below_minimum_operation_mode text,
  post_min_discount_enabled boolean,post_min_discount_bps integer,
  effective_from timestamptz,effective_to timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select vro.id,v.operator_id,vro.vehicle_id,vro.route_id,coalesce(r.route_name,r.name),
    vro.service_id,s.days_of_week,s.departure_time,s.timezone,
    vro.preferred_captain_id,concat_ws(' ',pc.first_name,pc.last_name),
    vro.preferred,vro.active,vro.min_seats,vro.max_seats,vro.min_revenue_cents,
    vro.min_value_threshold_ratio,vro.below_minimum_operation_mode,
    vro.post_min_discount_enabled,vro.post_min_discount_bps,vro.effective_from,vro.effective_to
  from pace_v2.vehicle_route_offers vro
  join pace_v2.vehicles v on v.id=vro.vehicle_id
  join pace_v2.routes r on r.id=vro.route_id
  join pace_v2.services s on s.id=vro.service_id and s.route_id=vro.route_id
  left join pace_v2.captains pc on pc.id=vro.preferred_captain_id
  where auth.uid() is not null and pace_v2.has_operator_access(v.operator_id)
    and vro.effective_to is null
  order by coalesce(r.route_name,r.name),s.days_of_week,s.departure_time;
$$;

revoke all on function public.v2_operator_load_vehicle_editor_offers() from public, anon, authenticated;
grant execute on function public.v2_operator_load_vehicle_editor_offers() to authenticated;

create or replace function public.v2_operator_save_vehicle(p_vehicle jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_vehicle_id uuid := nullif(p_vehicle->>'vehicle_id','')::uuid;
  v_requested_operator_id uuid := nullif(p_vehicle->>'operator_id','')::uuid;
  v_expected_updated_at timestamptz := nullif(p_vehicle->>'expected_updated_at','')::timestamptz;
  v_operator_id uuid;
  v_vehicle_type_id uuid := nullif(p_vehicle->>'vehicle_type_id','')::uuid;
  v_captain_id uuid := nullif(p_vehicle->>'preferred_captain_id','')::uuid;
  v_capacity integer := (p_vehicle->>'capacity_seats')::integer;
  v_offer jsonb;
  v_offer_id uuid;
  v_service_id uuid;
  v_submitted_route_id uuid;
  v_route_id uuid;
  v_offer_captain_id uuid;
  v_mode text;
  v_threshold numeric;
  v_min_seats integer;
  v_max_seats integer;
  v_min_revenue integer;
  v_discount_enabled boolean;
  v_discount_bps integer;
  v_target_active boolean := coalesce((p_vehicle->>'active')::boolean,true);
  v_existing pace_v2.vehicle_route_offers%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required'; end if;
  if trim(coalesce(p_vehicle->>'name','')) = '' then raise exception 'vehicle name required'; end if;
  if v_vehicle_type_id is null then raise exception 'Transport Type required'; end if;
  if v_capacity is null or v_capacity < 1 then raise exception 'passenger capacity must be at least 1'; end if;

  if v_vehicle_id is not null then
    select operator_id into v_operator_id from pace_v2.vehicles where id=v_vehicle_id for update;
    if v_operator_id is null then raise exception 'vehicle not found'; end if;
    if v_requested_operator_id is not null and v_operator_id<>v_requested_operator_id then raise exception 'vehicle does not belong to selected operator'; end if;
    if not pace_v2.has_operator_access(v_operator_id) then raise exception 'operator access required'; end if;
    if v_expected_updated_at is null or not exists (
      select 1 from pace_v2.vehicles where id=v_vehicle_id and updated_at=v_expected_updated_at
    ) then raise exception 'vehicle was changed by another user; reload before saving'; end if;
  else
    if pace_v2.is_site_admin() then
      select o.id into v_operator_id from pace_v2.operators o where o.id=v_requested_operator_id;
    else
      select om.operator_id into v_operator_id
      from pace_v2.operator_memberships om
      where om.user_id=auth.uid() and om.active and om.operator_id=v_requested_operator_id
      order by om.created_at
      limit 1;
    end if;
    if v_operator_id is null then raise exception 'operator access required'; end if;
  end if;

  if v_vehicle_id is not null and exists (
    select 1 from pace_v2.vehicle_route_offers current_offer
    where current_offer.vehicle_id=v_vehicle_id and current_offer.effective_to is null
      and not exists (
        select 1 from jsonb_array_elements(coalesce(p_vehicle->'route_offers','[]'::jsonb)) submitted
        where nullif(submitted->>'offer_id','')::uuid=current_offer.id
      )
  ) then raise exception 'all current Route Offers must be submitted or explicitly removed'; end if;

  if not exists (
    select 1 from pace_v2.operator_vehicle_types ovt
    join pace_v2.vehicle_types vt on vt.id=ovt.vehicle_type_id and vt.active
    where ovt.operator_id=v_operator_id and ovt.vehicle_type_id=v_vehicle_type_id and ovt.status='approved'
  ) then raise exception 'Transport Type is not approved for this operator'; end if;

  if v_captain_id is not null and not exists (
    select 1 from pace_v2.captains c
    join pace_v2.captain_vehicle_types cvt on cvt.captain_id=c.id and cvt.active
    where c.id=v_captain_id and c.operator_id=v_operator_id and c.active
      and cvt.vehicle_type_id=v_vehicle_type_id
  ) then raise exception 'preferred captain is not eligible for this vehicle'; end if;

  if v_vehicle_id is null then
    insert into pace_v2.vehicles(
      operator_id,vehicle_type_id,name,description,picture_url,active,
      capacity_seats,capacity_source,capacity_verified_at,
      default_min_seats,default_max_seats,default_min_revenue_cents,
      default_min_value_threshold_ratio,default_max_seat_discount_bps
    ) values (
      v_operator_id,v_vehicle_type_id,trim(p_vehicle->>'name'),
      nullif(trim(coalesce(p_vehicle->>'description','')),''),nullif(p_vehicle->>'picture_url',''),
      true,v_capacity,'operator_entered',now(),
      1,v_capacity,0,null,0
    ) returning id into v_vehicle_id;
  else
    update pace_v2.vehicle_route_offers current_offer
    set active=false,effective_to=coalesce(effective_to,now()),updated_at=now()
    where current_offer.vehicle_id=v_vehicle_id and current_offer.effective_to is null
      and current_offer.max_seats>v_capacity
      and exists (
        select 1 from jsonb_array_elements(coalesce(p_vehicle->'route_offers','[]'::jsonb)) submitted
        where nullif(submitted->>'offer_id','')::uuid=current_offer.id
          and (
            coalesce((submitted->>'remove')::boolean,false)
            or (submitted->>'max_seats')::integer<=v_capacity
          )
      );
    update pace_v2.vehicles set
      vehicle_type_id=v_vehicle_type_id,
      name=trim(p_vehicle->>'name'),
      description=nullif(trim(coalesce(p_vehicle->>'description','')),''),
      picture_url=nullif(p_vehicle->>'picture_url',''),
      capacity_seats=v_capacity,
      capacity_source='operator_entered',
      capacity_verified_at=now()
    where id=v_vehicle_id and operator_id=v_operator_id;
  end if;

  if v_target_active then update pace_v2.vehicles set active=true where id=v_vehicle_id; end if;

  update pace_v2.vehicle_captain_preferences
  set active=false,updated_at=now()
  where vehicle_id=v_vehicle_id and operator_id=v_operator_id and active;

  if v_captain_id is not null then
    insert into pace_v2.vehicle_captain_preferences(operator_id,vehicle_id,captain_id,priority,active)
    values(v_operator_id,v_vehicle_id,v_captain_id,1,true)
    on conflict(vehicle_id,captain_id) do update set priority=1,active=true,updated_at=now();
  end if;

  if jsonb_typeof(coalesce(p_vehicle->'route_offers','[]'::jsonb)) <> 'array' then
    raise exception 'route_offers must be an array';
  end if;

  if exists (
    select 1 from jsonb_array_elements(coalesce(p_vehicle->'route_offers','[]'::jsonb)) a
    where coalesce((a->>'remove')::boolean,false)=false
    group by a->>'service_id' having count(*) > 1
  ) then raise exception 'duplicate service offers are not allowed'; end if;

  for v_offer in select value from jsonb_array_elements(coalesce(p_vehicle->'route_offers','[]'::jsonb)) loop
    v_offer_id := nullif(v_offer->>'offer_id','')::uuid;
    v_service_id := nullif(v_offer->>'service_id','')::uuid;
    v_submitted_route_id := nullif(v_offer->>'route_id','')::uuid;
    v_offer_captain_id := nullif(v_offer->>'preferred_captain_id','')::uuid;

    if v_offer_id is not null then
      select * into v_existing
      from pace_v2.vehicle_route_offers
      where id=v_offer_id and vehicle_id=v_vehicle_id
      for update;
      if not found then raise exception 'Route Offer does not belong to this vehicle'; end if;
    end if;

    if coalesce((v_offer->>'remove')::boolean,false) then
      if v_offer_id is not null then
        update pace_v2.vehicle_route_offers
        set active=false,effective_to=coalesce(effective_to,now()),updated_at=now()
        where id=v_offer_id;
      end if;
      continue;
    end if;

    if v_service_id is null then raise exception 'service required'; end if;
    select s.route_id into v_route_id
    from pace_v2.services s
    where s.id=v_service_id and s.active
    for share;
    if not found then raise exception 'active service required'; end if;
    if v_submitted_route_id is distinct from v_route_id then
      raise exception 'selected service does not belong to the submitted route';
    end if;

    if not exists (
      select 1 from public.v2_operator_vehicle_editor_routes er
      where er.operator_id=v_operator_id and er.route_id=v_route_id and er.vehicle_type_id=v_vehicle_type_id
    ) then raise exception 'service is not eligible for this operator and Transport Type'; end if;

    if exists (
      select 1 from pace_v2.vehicle_route_offers current_offer
      where current_offer.vehicle_id=v_vehicle_id
        and current_offer.service_id=v_service_id
        and current_offer.effective_to is null
        and (v_offer_id is null or current_offer.id<>v_offer_id)
    ) then raise exception 'duplicate service offers are not allowed'; end if;

    if v_offer_captain_id is not null and not exists (
      select 1 from pace_v2.captains c
      join pace_v2.captain_vehicle_types cvt on cvt.captain_id=c.id and cvt.active
      where c.id=v_offer_captain_id and c.operator_id=v_operator_id and c.active
        and cvt.vehicle_type_id=v_vehicle_type_id
    ) then raise exception 'Route Offer captain is not eligible for this vehicle'; end if;

    v_min_seats := (v_offer->>'min_seats')::integer;
    v_max_seats := (v_offer->>'max_seats')::integer;
    v_min_revenue := (v_offer->>'min_revenue_cents')::integer;
    v_discount_enabled := coalesce((v_offer->>'post_min_discount_enabled')::boolean,false);
    v_discount_bps := coalesce((v_offer->>'post_min_discount_bps')::integer,0);
    v_mode := v_offer->>'below_minimum_operation_mode';
    v_threshold := nullif(v_offer->>'min_value_threshold_ratio','')::numeric;

    if v_min_seats < 1 or v_max_seats < v_min_seats or v_max_seats > v_capacity then
      raise exception 'Route Offer seat limits are invalid';
    end if;
    if v_min_revenue < 0 then raise exception 'minimum journey revenue cannot be negative'; end if;
    if (v_discount_enabled and (v_discount_bps<=0 or v_discount_bps>10000)) or v_discount_bps<0 then
      raise exception 'enabled discount must be greater than 0 and no more than 100 percent';
    end if;
    if not v_discount_enabled then v_discount_bps := 0; end if;
    if v_mode not in ('never','route_default','custom_threshold') then raise exception 'invalid below-minimum operation mode'; end if;
    if v_mode='custom_threshold' and (v_threshold is null or v_threshold<=0 or v_threshold>1) then
      raise exception 'custom operating threshold must be greater than 0 and no more than 100 percent';
    end if;
    if v_mode<>'custom_threshold' then v_threshold := null; end if;

    if v_offer_id is not null
      and v_existing.service_id = v_service_id
      and v_existing.route_id = v_route_id
      and v_existing.preferred_captain_id is not distinct from v_offer_captain_id
      and v_existing.preferred = coalesce((v_offer->>'preferred')::boolean,false)
      and v_existing.active = coalesce((v_offer->>'active')::boolean,true)
      and v_existing.min_seats = v_min_seats
      and v_existing.max_seats = v_max_seats
      and v_existing.min_revenue_cents = v_min_revenue
      and v_existing.min_value_threshold_ratio is not distinct from v_threshold
      and v_existing.below_minimum_operation_mode = v_mode
      and v_existing.post_min_discount_enabled = v_discount_enabled
      and v_existing.post_min_discount_bps = v_discount_bps
    then continue; end if;

    if v_offer_id is not null then
      update pace_v2.vehicle_route_offers
      set active=false,effective_to=coalesce(effective_to,now()),updated_at=now()
      where id=v_offer_id;
    end if;

    insert into pace_v2.vehicle_route_offers(
      vehicle_id,service_id,route_id,preferred_captain_id,preferred,active,
      min_seats,max_seats,min_revenue_cents,
      min_value_threshold_ratio,below_minimum_operation_mode,
      post_min_discount_enabled,post_min_discount_bps,effective_from,effective_to
    ) values (
      v_vehicle_id,v_service_id,v_route_id,v_offer_captain_id,
      coalesce((v_offer->>'preferred')::boolean,false),
      coalesce((v_offer->>'active')::boolean,true),
      v_min_seats,v_max_seats,v_min_revenue,
      v_threshold,v_mode,v_discount_enabled,v_discount_bps,now(),null
    );
  end loop;

  update pace_v2.vehicles
  set active=v_target_active
  where id=v_vehicle_id and operator_id=v_operator_id;

  return v_vehicle_id;
end;
$$;

revoke all on function public.v2_operator_save_vehicle(jsonb) from public, anon, authenticated;
grant execute on function public.v2_operator_save_vehicle(jsonb) to authenticated;

drop function if exists public.v2_admin_create_route_offer(uuid,uuid,integer,integer,integer,boolean,numeric,boolean,integer);
create function public.v2_admin_create_route_offer(
  p_vehicle_id uuid,p_service_id uuid,
  p_min_seats integer,p_max_seats integer,p_min_revenue_cents integer,
  p_preferred boolean default false,
  p_min_value_threshold_ratio numeric default null,
  p_post_min_discount_enabled boolean default false,
  p_post_min_discount_bps integer default 0
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_route_id uuid;
  v_operator_id uuid;
  v_vehicle_type_id uuid;
  v_capacity integer;
  v_discount_enabled boolean := coalesce(p_post_min_discount_enabled,false);
  v_discount_bps integer := coalesce(p_post_min_discount_bps,0);
begin
  if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;

  select v.operator_id,v.vehicle_type_id,v.capacity_seats
  into v_operator_id,v_vehicle_type_id,v_capacity
  from pace_v2.vehicles v
  where v.id=p_vehicle_id
  for update;
  if not found then raise exception 'vehicle not found'; end if;

  select s.route_id into v_route_id
  from pace_v2.services s
  where s.id=p_service_id and s.active
  for share;
  if not found then raise exception 'active service required'; end if;

  if not exists (
    select 1 from public.v2_operator_vehicle_editor_routes er
    where er.operator_id=v_operator_id and er.route_id=v_route_id and er.vehicle_type_id=v_vehicle_type_id
  ) then raise exception 'service is not eligible for this operator and Transport Type'; end if;

  if exists (
    select 1 from pace_v2.vehicle_route_offers current_offer
    where current_offer.vehicle_id=p_vehicle_id
      and current_offer.service_id=p_service_id
      and current_offer.effective_to is null
  ) then raise exception 'duplicate service offers are not allowed'; end if;

  if p_min_seats<1 or p_max_seats<p_min_seats or p_max_seats>v_capacity then
    raise exception 'Route Offer seat limits are invalid';
  end if;
  if p_min_revenue_cents<0 then raise exception 'minimum journey revenue cannot be negative'; end if;
  if p_min_value_threshold_ratio is not null
    and (p_min_value_threshold_ratio<=0 or p_min_value_threshold_ratio>1)
  then raise exception 'custom operating threshold must be greater than 0 and no more than 100 percent'; end if;
  if (v_discount_enabled and (v_discount_bps<=0 or v_discount_bps>10000)) or v_discount_bps<0 then
    raise exception 'enabled discount must be greater than 0 and no more than 100 percent';
  end if;
  if not v_discount_enabled then v_discount_bps := 0; end if;

  insert into pace_v2.vehicle_route_offers(
    vehicle_id,service_id,route_id,preferred,active,
    min_seats,max_seats,min_revenue_cents,
    min_value_threshold_ratio,below_minimum_operation_mode,
    post_min_discount_enabled,post_min_discount_bps
  ) values (
    p_vehicle_id,p_service_id,v_route_id,coalesce(p_preferred,false),true,
    p_min_seats,p_max_seats,p_min_revenue_cents,
    p_min_value_threshold_ratio,
    case when p_min_value_threshold_ratio is null then 'route_default' else 'custom_threshold' end,
    v_discount_enabled,v_discount_bps
  ) returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.v2_admin_create_route_offer(uuid,uuid,integer,integer,integer,boolean,numeric,boolean,integer) from public, anon, authenticated;
grant execute on function public.v2_admin_create_route_offer(uuid,uuid,integer,integer,integer,boolean,numeric,boolean,integer) to authenticated;

-- Preserve the allocation candidate contract while scoping each offer to the
-- recurring service scheduled by the requested departure.
create or replace function pace_v2.get_eligible_vehicle_offers(p_departure_id uuid)
returns table(
  departure_id uuid,
  route_id uuid,
  vehicle_route_offer_id uuid,
  vehicle_id uuid,
  operator_id uuid,
  vehicle_type_id uuid,
  normal_min_seats integer,
  max_seats integer,
  min_revenue_cents integer,
  min_value_threshold_ratio numeric,
  normal_base_seat_price_cents integer,
  quality_score numeric,
  effective_commission_bps integer,
  effective_commission_source text
)
language sql
stable
security definer
set search_path = pace_v2, public
as $eligibility$
  with dep as (
    select
      d.id,
      d.service_id,
      d.route_id,
      d.scheduled_departure_ts,
      d.scheduled_arrival_ts,
      r.country_id
    from pace_v2.departures d
    join pace_v2.routes r on r.id = d.route_id
    where d.id = p_departure_id
      and d.status not in ('cancelled','completed')
  ),
  candidates as (
    select
      d.id as departure_id,
      d.route_id,
      vro.id as vehicle_route_offer_id,
      v.id as vehicle_id,
      v.operator_id,
      v.vehicle_type_id,
      vro.min_seats,
      vro.max_seats,
      vro.min_revenue_cents,
      vro.min_value_threshold_ratio,
      ceil(vro.min_revenue_cents::numeric / vro.min_seats)::integer as base_seat_price,
      o.quality_score,
      d.country_id,
      d.scheduled_departure_ts
    from dep d
    join pace_v2.vehicle_route_offers vro
      on vro.service_id = d.service_id
     and vro.active = true
     and vro.effective_from <= d.scheduled_departure_ts
     and (vro.effective_to is null or vro.effective_to > d.scheduled_departure_ts)
    join pace_v2.vehicles v
      on v.id = vro.vehicle_id
     and v.active = true
    join pace_v2.operators o
      on o.id = v.operator_id
     and o.active = true
    join pace_v2.operator_vehicle_types ovt
      on ovt.operator_id = v.operator_id
     and ovt.vehicle_type_id = v.vehicle_type_id
     and ovt.status = 'approved'
    where exists (
      select 1
      from pace_v2.route_vehicle_types rvt
      where rvt.route_id = d.route_id
        and rvt.vehicle_type_id = v.vehicle_type_id
        and rvt.active = true
        and rvt.effective_from <= d.scheduled_departure_ts
        and (rvt.effective_to is null or rvt.effective_to > d.scheduled_departure_ts)
    )
    and not exists (
      select 1
      from pace_v2.vehicle_availability_exceptions vae
      where vae.vehicle_id = v.id
        and vae.start_ts < coalesce(d.scheduled_arrival_ts, d.scheduled_departure_ts + interval '8 hours')
        and vae.end_ts > d.scheduled_departure_ts
    )
  )
  select
    c.departure_id,
    c.route_id,
    c.vehicle_route_offer_id,
    c.vehicle_id,
    c.operator_id,
    c.vehicle_type_id,
    c.min_seats as normal_min_seats,
    c.max_seats,
    c.min_revenue_cents,
    c.min_value_threshold_ratio,
    c.base_seat_price as normal_base_seat_price_cents,
    c.quality_score,
    ec.commission_bps as effective_commission_bps,
    ec.commission_source as effective_commission_source
  from candidates c
  left join lateral pace_v2.get_effective_commission(
    c.operator_id,
    c.country_id,
    c.scheduled_departure_ts
  ) ec on true;
$eligibility$;
