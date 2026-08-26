-- Replace browser-facing definer views with tightly scoped authenticated RPCs.

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

create or replace function public.v2_operator_load_vehicle_editor_captains()
returns table(operator_id uuid,captain_id uuid,captain_name text,email text,vehicle_type_id uuid)
language sql stable security definer set search_path=public,pace_v2,auth as $$
 select c.operator_id,c.id,concat_ws(' ',c.first_name,c.last_name),c.email,cvt.vehicle_type_id
 from pace_v2.captains c join pace_v2.captain_vehicle_types cvt on cvt.captain_id=c.id and cvt.active
 where auth.uid() is not null and c.active and pace_v2.has_operator_access(c.operator_id) order by c.first_name,c.last_name;
$$;

create or replace function public.v2_operator_load_vehicle_editor_types()
returns table(operator_id uuid,vehicle_type_id uuid,vehicle_type_name text)
language sql stable security definer set search_path=public,pace_v2,auth as $$
 select ovt.operator_id,vt.id,vt.name from pace_v2.operator_vehicle_types ovt
 join pace_v2.vehicle_types vt on vt.id=ovt.vehicle_type_id and vt.active
 where auth.uid() is not null and ovt.status='approved' and pace_v2.has_operator_access(ovt.operator_id) order by vt.name;
$$;

create or replace function public.v2_operator_load_vehicle_editor_routes()
returns table(operator_id uuid,route_id uuid,route_name text,vehicle_type_id uuid,country_id uuid,locality_id uuid)
language sql stable security definer set search_path=public,pace_v2,auth as $$
 select er.operator_id,er.route_id,er.route_name,er.vehicle_type_id,er.country_id,er.locality_id
 from public.v2_operator_vehicle_editor_routes er where auth.uid() is not null order by er.route_name;
$$;

create or replace function public.v2_operator_load_vehicle_editor_offers()
returns table(offer_id uuid,operator_id uuid,vehicle_id uuid,route_id uuid,route_name text,preferred boolean,active boolean,min_seats integer,max_seats integer,min_revenue_cents integer,min_value_threshold_ratio numeric,below_minimum_operation_mode text,post_min_discount_enabled boolean,post_min_discount_bps integer,effective_from timestamptz,effective_to timestamptz)
language sql stable security definer set search_path=public,pace_v2,auth as $$
 select vro.id,v.operator_id,vro.vehicle_id,vro.route_id,coalesce(r.route_name,r.name),vro.preferred,vro.active,vro.min_seats,vro.max_seats,vro.min_revenue_cents,vro.min_value_threshold_ratio,vro.below_minimum_operation_mode,vro.post_min_discount_enabled,vro.post_min_discount_bps,vro.effective_from,vro.effective_to
 from pace_v2.vehicle_route_offers vro join pace_v2.vehicles v on v.id=vro.vehicle_id join pace_v2.routes r on r.id=vro.route_id
 where auth.uid() is not null and pace_v2.has_operator_access(v.operator_id) and vro.effective_to is null order by coalesce(r.route_name,r.name);
$$;

revoke all on function public.v2_operator_load_vehicle_editor() from public,anon;
revoke all on function public.v2_operator_load_vehicle_editor_captains() from public,anon;
revoke all on function public.v2_operator_load_vehicle_editor_types() from public,anon;
revoke all on function public.v2_operator_load_vehicle_editor_routes() from public,anon;
revoke all on function public.v2_operator_load_vehicle_editor_offers() from public,anon;
grant execute on function public.v2_operator_load_vehicle_editor() to authenticated;
grant execute on function public.v2_operator_load_vehicle_editor_captains() to authenticated;
grant execute on function public.v2_operator_load_vehicle_editor_types() to authenticated;
grant execute on function public.v2_operator_load_vehicle_editor_routes() to authenticated;
grant execute on function public.v2_operator_load_vehicle_editor_offers() to authenticated;

drop view public.v2_operator_vehicle_editor;
drop view public.v2_operator_vehicle_editor_captains;
drop view public.v2_operator_vehicle_editor_types;
drop view public.v2_operator_vehicle_editor_offers;
