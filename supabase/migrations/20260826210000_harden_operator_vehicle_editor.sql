-- Close review findings in the operator vehicle editor after the initial live rollout.

alter table pace_v2.vehicle_route_offers drop constraint if exists vehicle_route_offer_below_minimum_mode_check;
alter table pace_v2.vehicle_route_offers add constraint vehicle_route_offer_below_minimum_mode_check check (
  below_minimum_operation_mode in ('never','route_default','custom_threshold') and (
    (below_minimum_operation_mode='custom_threshold' and min_value_threshold_ratio>0 and min_value_threshold_ratio<=1)
    or (below_minimum_operation_mode<>'custom_threshold' and min_value_threshold_ratio is null)
  )
);
alter table pace_v2.vehicle_considerations drop constraint if exists vehicle_consideration_below_minimum_mode_check;
alter table pace_v2.vehicle_considerations add constraint vehicle_consideration_below_minimum_mode_check check (
  below_minimum_operation_mode in ('never','route_default','custom_threshold') and (
    (below_minimum_operation_mode='custom_threshold' and min_value_threshold_ratio>0 and min_value_threshold_ratio<=1)
    or (below_minimum_operation_mode='route_default' and (min_value_threshold_ratio is null or (min_value_threshold_ratio>0 and min_value_threshold_ratio<=1)))
    or (below_minimum_operation_mode='never' and min_value_threshold_ratio is null)
  )
);

create or replace function pace_v2.sync_consideration_below_minimum_mode()
returns trigger language plpgsql set search_path=pace_v2,public as $$
declare v_mode text; v_default_ratio numeric;
begin
  if new.vehicle_route_offer_id is not null then
    select vro.below_minimum_operation_mode,v.default_min_value_threshold_ratio into v_mode,v_default_ratio
    from pace_v2.vehicle_route_offers vro join pace_v2.vehicles v on v.id=vro.vehicle_id
    where vro.id=new.vehicle_route_offer_id;
    new.below_minimum_operation_mode:=v_mode;
    new.min_value_threshold_ratio:=case when v_mode='never' then null when v_mode='route_default' then v_default_ratio else new.min_value_threshold_ratio end;
  end if;
  return new;
end; $$;

create or replace function pace_v2.validate_vehicle_capacity_change()
returns trigger language plpgsql set search_path=pace_v2,public as $$
declare v_largest_offer integer;
begin
 select max(vro.max_seats) into v_largest_offer from pace_v2.vehicle_route_offers vro
 where vro.vehicle_id=new.id and vro.active and vro.effective_to is null;
 if v_largest_offer is not null and new.capacity_seats<v_largest_offer then
  raise exception 'Vehicle capacity % is below current Route Offer maximum seats %',new.capacity_seats,v_largest_offer;
 end if;
 return new;
end; $$;

drop function public.v2_operator_load_vehicle_editor();
alter view public.v2_operator_vehicle_editor_routes set (security_invoker=true);
revoke all on public.v2_operator_vehicle_editor_routes from public, anon, authenticated;

create or replace function public.v2_operator_load_vehicle_editor()
returns table(vehicle_id uuid,operator_id uuid,vehicle_type_id uuid,vehicle_type_name text,name text,description text,picture_url text,capacity_seats integer,active boolean,preferred_captain_id uuid,preferred_captain_name text,updated_at timestamptz)
language sql stable security definer set search_path=public,pace_v2,auth as $$
 select v.id,v.operator_id,v.vehicle_type_id,vt.name,v.name,v.description,v.picture_url,v.capacity_seats,v.active,pref.captain_id,concat_ws(' ',pc.first_name,pc.last_name),v.updated_at
 from pace_v2.vehicles v join pace_v2.vehicle_types vt on vt.id=v.vehicle_type_id
 left join lateral (select vcp.captain_id from pace_v2.vehicle_captain_preferences vcp where vcp.vehicle_id=v.id and vcp.operator_id=v.operator_id and vcp.active order by vcp.priority,vcp.created_at limit 1) pref on true
 left join pace_v2.captains pc on pc.id=pref.captain_id
 where auth.uid() is not null and pace_v2.has_operator_access(v.operator_id) order by v.name;
$$;

revoke all on function public.v2_operator_load_vehicle_editor() from public,anon;
grant execute on function public.v2_operator_load_vehicle_editor() to authenticated;

create or replace function public.v2_operator_save_vehicle(p_vehicle jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, pace_v2, auth
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
  v_route_id uuid;
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
    select operator_id into v_operator_id from pace_v2.vehicles where id = v_vehicle_id for update;
    if v_operator_id is null then raise exception 'vehicle not found'; end if;
    if not pace_v2.has_operator_access(v_operator_id) then raise exception 'operator access required'; end if;
    if v_expected_updated_at is null or not exists (select 1 from pace_v2.vehicles where id=v_vehicle_id and updated_at=v_expected_updated_at) then
      raise exception 'vehicle was changed by another user; reload before saving';
    end if;
  else
    select om.operator_id into v_operator_id
    from pace_v2.operator_memberships om
    where om.user_id = auth.uid() and om.active and om.operator_id=v_requested_operator_id
    order by om.created_at
    limit 1;
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
    join pace_v2.vehicle_types vt on vt.id = ovt.vehicle_type_id and vt.active
    where ovt.operator_id = v_operator_id and ovt.vehicle_type_id = v_vehicle_type_id and ovt.status = 'approved'
  ) then raise exception 'Transport Type is not approved for this operator'; end if;

  if v_captain_id is not null and not exists (
    select 1 from pace_v2.captains c
    join pace_v2.captain_vehicle_types cvt on cvt.captain_id = c.id and cvt.active
    where c.id = v_captain_id and c.operator_id = v_operator_id and c.active
      and cvt.vehicle_type_id = v_vehicle_type_id
  ) then raise exception 'preferred captain is not eligible for this vehicle'; end if;

  if v_vehicle_id is null then
    insert into pace_v2.vehicles(
      operator_id, vehicle_type_id, name, description, picture_url, active,
      capacity_seats, capacity_source, capacity_verified_at,
      default_min_seats, default_max_seats, default_min_revenue_cents,
      default_min_value_threshold_ratio, default_max_seat_discount_bps
    ) values (
      v_operator_id, v_vehicle_type_id, trim(p_vehicle->>'name'),
      nullif(trim(coalesce(p_vehicle->>'description','')),''), nullif(p_vehicle->>'picture_url',''),
      true, v_capacity, 'operator_entered', now(),
      1, v_capacity, 0, null, 0
    ) returning id into v_vehicle_id;
  else
    -- End submitted offers that exceed the proposed capacity before the guarded
    -- capacity update. The transaction rolls this back if later validation fails.
    update pace_v2.vehicle_route_offers current_offer
    set active=false,effective_to=coalesce(effective_to,now()),updated_at=now()
    where current_offer.vehicle_id=v_vehicle_id and current_offer.effective_to is null
      and current_offer.max_seats>v_capacity
      and exists (
        select 1 from jsonb_array_elements(coalesce(p_vehicle->'route_offers','[]'::jsonb)) submitted
        where nullif(submitted->>'offer_id','')::uuid=current_offer.id
          and (coalesce((submitted->>'remove')::boolean,false) or (submitted->>'max_seats')::integer<=v_capacity)
      );
    update pace_v2.vehicles set
      vehicle_type_id = v_vehicle_type_id,
      name = trim(p_vehicle->>'name'),
      description = nullif(trim(coalesce(p_vehicle->>'description','')),''),
      picture_url = nullif(p_vehicle->>'picture_url',''),
      capacity_seats = v_capacity,
      capacity_source = 'operator_entered',
      capacity_verified_at = now()
    where id = v_vehicle_id and operator_id = v_operator_id;
  end if;

  if v_target_active then update pace_v2.vehicles set active=true where id=v_vehicle_id; end if;

  update pace_v2.vehicle_captain_preferences
  set active = false, updated_at = now()
  where vehicle_id = v_vehicle_id and operator_id = v_operator_id and active;

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
    where coalesce((a->>'remove')::boolean,false) = false
    group by a->>'route_id' having count(*) > 1
  ) then raise exception 'duplicate route offers are not allowed'; end if;

  for v_offer in select value from jsonb_array_elements(coalesce(p_vehicle->'route_offers','[]'::jsonb)) loop
    v_offer_id := nullif(v_offer->>'offer_id','')::uuid;
    v_route_id := nullif(v_offer->>'route_id','')::uuid;

    if v_offer_id is not null then
      select * into v_existing from pace_v2.vehicle_route_offers where id=v_offer_id and vehicle_id=v_vehicle_id for update;
      if not found then raise exception 'Route Offer does not belong to this vehicle'; end if;
    end if;

    if coalesce((v_offer->>'remove')::boolean,false) then
      if v_offer_id is not null then
        update pace_v2.vehicle_route_offers set active=false,effective_to=coalesce(effective_to,now()),updated_at=now()
        where id=v_offer_id;
      end if;
      continue;
    end if;

    if v_route_id is null then raise exception 'route required'; end if;
    if not exists (
      select 1 from public.v2_operator_vehicle_editor_routes er
      where er.operator_id=v_operator_id and er.route_id=v_route_id and er.vehicle_type_id=v_vehicle_type_id
    ) then raise exception 'route is not eligible for this operator and Transport Type'; end if;

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
    if (v_discount_enabled and (v_discount_bps <= 0 or v_discount_bps > 10000)) or v_discount_bps < 0 then raise exception 'enabled discount must be greater than 0 and no more than 100 percent'; end if;
    if not v_discount_enabled then v_discount_bps := 0; end if;
    if v_mode not in ('never','route_default','custom_threshold') then raise exception 'invalid below-minimum operation mode'; end if;
    if v_mode='custom_threshold' and (v_threshold is null or v_threshold<=0 or v_threshold>1) then
      raise exception 'custom operating threshold must be greater than 0 and no more than 100 percent';
    end if;
    if v_mode<>'custom_threshold' then v_threshold := null; end if;

    if v_offer_id is not null
      and v_existing.route_id = v_route_id
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
      update pace_v2.vehicle_route_offers set active=false,effective_to=coalesce(effective_to,now()),updated_at=now()
      where id=v_offer_id;
    end if;

    insert into pace_v2.vehicle_route_offers(
      vehicle_id,route_id,preferred,active,min_seats,max_seats,min_revenue_cents,
      min_value_threshold_ratio,below_minimum_operation_mode,
      post_min_discount_enabled,post_min_discount_bps,effective_from,effective_to
    ) values (
      v_vehicle_id,v_route_id,coalesce((v_offer->>'preferred')::boolean,false),
      coalesce((v_offer->>'active')::boolean,true),v_min_seats,v_max_seats,v_min_revenue,
      v_threshold,v_mode,v_discount_enabled,v_discount_bps,now(),null
    );
  end loop;

  update pace_v2.vehicles set active=v_target_active where id=v_vehicle_id and operator_id=v_operator_id;

  return v_vehicle_id;
end;
$$;

revoke all on function public.v2_operator_save_vehicle(jsonb) from public, anon;
grant execute on function public.v2_operator_save_vehicle(jsonb) to authenticated;

