begin;

do $$
declare
  o pace_v2.vehicle_route_offers%rowtype;
  v_capacity integer;
  vc pace_v2.vehicle_considerations%rowtype;
  rejected boolean;
begin
  select * into o
  from pace_v2.vehicle_route_offers
  where active and effective_to is null
  order by created_at
  limit 1;
  if o.id is null then raise exception 'fixture: current Route Offer missing'; end if;

  select capacity_seats into v_capacity
  from pace_v2.vehicles where id = o.vehicle_id;

  rejected := false;
  begin
    insert into pace_v2.vehicle_route_offers(
      vehicle_id,route_id,preferred,active,min_seats,max_seats,
      min_revenue_cents,min_value_threshold_ratio,
      post_min_discount_enabled,post_min_discount_bps
    ) values (
      o.vehicle_id,o.route_id,false,false,1,v_capacity+1,
      o.min_revenue_cents,o.min_value_threshold_ratio,false,0
    );
  exception when others then
    if sqlerrm ilike '%exceed vehicle capacity%' then rejected := true;
    else raise; end if;
  end;
  if not rejected then raise exception 'oversized Route Offer was accepted'; end if;

  rejected := false;
  begin
    insert into pace_v2.vehicle_route_offers(
      vehicle_id,route_id,preferred,active,min_seats,max_seats,
      min_revenue_cents,min_value_threshold_ratio,
      post_min_discount_enabled,post_min_discount_bps
    ) values (
      o.vehicle_id,o.route_id,false,true,o.min_seats,o.max_seats,
      o.min_revenue_cents,o.min_value_threshold_ratio,
      o.post_min_discount_enabled,o.post_min_discount_bps
    );
  exception when unique_violation then rejected := true;
  end;
  if not rejected then raise exception 'duplicate current Route Offer was accepted'; end if;

  insert into pace_v2.vehicle_route_offers(
    vehicle_id,route_id,preferred,active,min_seats,max_seats,
    min_revenue_cents,min_value_threshold_ratio,
    post_min_discount_enabled,post_min_discount_bps,effective_from,effective_to
  ) values (
    o.vehicle_id,o.route_id,false,false,o.min_seats,o.max_seats,
    o.min_revenue_cents,o.min_value_threshold_ratio,
    o.post_min_discount_enabled,o.post_min_discount_bps,
    now()-interval '2 minutes',now()-interval '1 minute'
  );

  rejected := false;
  begin
    update pace_v2.vehicles
    set capacity_seats = o.max_seats-1
    where id = o.vehicle_id;
  exception when others then
    if sqlerrm ilike '%below existing Route Offer maximum%' then rejected := true;
    else raise; end if;
  end;
  if not rejected then raise exception 'unsafe capacity reduction was accepted'; end if;

  select * into vc
  from pace_v2.vehicle_considerations
  where assigned_seats > 0
  order by created_at
  limit 1;
  if vc.id is null then raise exception 'fixture: allocated consideration missing'; end if;

  update pace_v2.vehicle_considerations
  set assigned_seats = 0
  where id = vc.id;

  rejected := false;
  begin
    update pace_v2.vehicle_considerations
    set post_min_discount_bps = case when post_min_discount_bps=0 then 100 else 0 end
    where id = vc.id;
  exception when others then
    if sqlerrm ilike '%snapshot is immutable%' then rejected := true;
    else raise; end if;
  end;
  if not rejected then raise exception 'discount snapshot was mutable after seats reset'; end if;

  rejected := false;
  begin
    delete from pace_v2.vehicle_considerations where id = vc.id;
  exception when others then
    if sqlerrm ilike '%cannot be deleted%' then rejected := true;
    else raise; end if;
  end;
  if not rejected then raise exception 'allocated snapshot could be deleted'; end if;
end
$$;

rollback;
