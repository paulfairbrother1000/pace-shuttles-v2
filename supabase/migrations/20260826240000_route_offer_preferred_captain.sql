alter table pace_v2.vehicle_route_offers
  add column if not exists preferred_captain_id uuid references pace_v2.captains(id);

create index if not exists vehicle_route_offers_preferred_captain_idx
  on pace_v2.vehicle_route_offers(preferred_captain_id)
  where preferred_captain_id is not null;

drop function public.v2_operator_load_vehicle_editor_offers();
create function public.v2_operator_load_vehicle_editor_offers()
returns table(
  offer_id uuid,operator_id uuid,vehicle_id uuid,route_id uuid,route_name text,
  preferred_captain_id uuid,preferred_captain_name text,preferred boolean,active boolean,
  min_seats integer,max_seats integer,min_revenue_cents integer,
  min_value_threshold_ratio numeric,below_minimum_operation_mode text,
  post_min_discount_enabled boolean,post_min_discount_bps integer,
  effective_from timestamptz,effective_to timestamptz
)
language sql stable security definer set search_path=public,pace_v2,auth as $$
 select vro.id,v.operator_id,vro.vehicle_id,vro.route_id,coalesce(r.route_name,r.name),
   vro.preferred_captain_id,concat_ws(' ',pc.first_name,pc.last_name),
   vro.preferred,vro.active,vro.min_seats,vro.max_seats,vro.min_revenue_cents,
   vro.min_value_threshold_ratio,vro.below_minimum_operation_mode,
   vro.post_min_discount_enabled,vro.post_min_discount_bps,vro.effective_from,vro.effective_to
 from pace_v2.vehicle_route_offers vro
 join pace_v2.vehicles v on v.id=vro.vehicle_id
 join pace_v2.routes r on r.id=vro.route_id
 left join pace_v2.captains pc on pc.id=vro.preferred_captain_id
 where auth.uid() is not null and pace_v2.has_operator_access(v.operator_id)
   and vro.effective_to is null
 order by coalesce(r.route_name,r.name);
$$;
revoke all on function public.v2_operator_load_vehicle_editor_offers() from public,anon;
grant execute on function public.v2_operator_load_vehicle_editor_offers() to authenticated;

do $$
declare
  v_definition text;
begin
  select pg_get_functiondef(p.oid) into v_definition
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='v2_operator_save_vehicle'
    and pg_get_function_identity_arguments(p.oid)='p_vehicle jsonb';
  if v_definition is null then raise exception 'v2_operator_save_vehicle(jsonb) is missing'; end if;

  v_definition := replace(v_definition,
    '  v_route_id uuid;',
    '  v_route_id uuid;'||chr(10)||'  v_offer_captain_id uuid;');
  v_definition := replace(v_definition,
    '    v_route_id := nullif(v_offer->>''route_id'','''')::uuid;',
    '    v_route_id := nullif(v_offer->>''route_id'','''')::uuid;'||chr(10)||
    '    v_offer_captain_id := nullif(v_offer->>''preferred_captain_id'','''')::uuid;');
  v_definition := replace(v_definition,
    '    v_min_seats := (v_offer->>''min_seats'')::integer;',
    '    if v_offer_captain_id is not null and not exists ('||chr(10)||
    '      select 1 from pace_v2.captains c'||chr(10)||
    '      join pace_v2.captain_vehicle_types cvt on cvt.captain_id=c.id and cvt.active'||chr(10)||
    '      where c.id=v_offer_captain_id and c.operator_id=v_operator_id and c.active'||chr(10)||
    '        and cvt.vehicle_type_id=v_vehicle_type_id'||chr(10)||
    '    ) then raise exception ''Route Offer captain is not eligible for this vehicle''; end if;'||chr(10)||chr(10)||
    '    v_min_seats := (v_offer->>''min_seats'')::integer;');
  v_definition := replace(v_definition,
    '      and v_existing.route_id = v_route_id',
    '      and v_existing.route_id = v_route_id'||chr(10)||
    '      and v_existing.preferred_captain_id is not distinct from v_offer_captain_id');
  v_definition := replace(v_definition,
    '      vehicle_id,route_id,preferred,active,min_seats,max_seats,min_revenue_cents,',
    '      vehicle_id,route_id,preferred_captain_id,preferred,active,min_seats,max_seats,min_revenue_cents,');
  v_definition := replace(v_definition,
    '      v_vehicle_id,v_route_id,coalesce((v_offer->>''preferred'')::boolean,false),',
    '      v_vehicle_id,v_route_id,v_offer_captain_id,coalesce((v_offer->>''preferred'')::boolean,false),');

  if v_definition not ilike '%v_offer_captain_id%'
     or v_definition not ilike '%Route Offer captain is not eligible%'
     or v_definition not ilike '%vehicle_id,route_id,preferred_captain_id,preferred%'
  then raise exception 'failed to patch v2_operator_save_vehicle for Route Offer captains'; end if;
  execute v_definition;
end
$$;

create or replace function pace_v2.pick_default_captain(p_confirmed_allocation_id uuid)
returns table(captain_id uuid, priority integer)
language sql stable security definer
set search_path=pace_v2,public as $$
with target as (
  select ca.id as confirmed_allocation_id,ca.vehicle_id,ca.operator_id,
    v.vehicle_type_id,d.scheduled_departure_ts,
    coalesce(d.scheduled_arrival_ts,d.scheduled_departure_ts+interval '8 hours') as scheduled_end_ts,
    vro.preferred_captain_id as route_captain_id
  from pace_v2.confirmed_allocations ca
  join pace_v2.vehicles v on v.id=ca.vehicle_id
  join pace_v2.departures d on d.id=ca.departure_id
  left join pace_v2.vehicle_considerations vc on vc.id=ca.consideration_id
  left join pace_v2.vehicle_route_offers vro on vro.id=vc.vehicle_route_offer_id
  where ca.id=p_confirmed_allocation_id
), preferences as (
  select t.route_captain_id as captain_id,0 as priority from target t where t.route_captain_id is not null
  union all
  select vcp.captain_id,100+vcp.priority from target t
  join pace_v2.vehicle_captain_preferences vcp on vcp.vehicle_id=t.vehicle_id and vcp.operator_id=t.operator_id and vcp.active
  union all
  select c.id,10000 from target t
  join pace_v2.captains c on c.operator_id=t.operator_id and c.active
), ranked as (
  select p.captain_id,min(p.priority)::integer as priority
  from preferences p group by p.captain_id
), eligible as (
  select r.captain_id,r.priority
  from ranked r
  join target t on true
  join pace_v2.captains c on c.id=r.captain_id and c.operator_id=t.operator_id and c.active
  join pace_v2.captain_vehicle_types cvt on cvt.captain_id=c.id and cvt.vehicle_type_id=t.vehicle_type_id and cvt.active
  where not exists (
    select 1 from pace_v2.captain_assignments ca2
    join pace_v2.confirmed_allocations cfa2 on cfa2.id=ca2.confirmed_allocation_id
    join pace_v2.departures d2 on d2.id=cfa2.departure_id
    where ca2.captain_id=c.id and ca2.active and cfa2.status='confirmed'
      and cfa2.id<>p_confirmed_allocation_id
      and d2.scheduled_departure_ts<t.scheduled_end_ts
      and coalesce(d2.scheduled_arrival_ts,d2.scheduled_departure_ts+interval '8 hours')>t.scheduled_departure_ts
  )
)
select e.captain_id,e.priority from eligible e order by e.priority,e.captain_id limit 1;
$$;

revoke all on function pace_v2.pick_default_captain(uuid) from public,anon,authenticated;
