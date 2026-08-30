alter table pace_v2.countries
  add column if not exists customer_availability_paused boolean not null default false,
  add column if not exists customer_pause_reason text,
  add column if not exists customer_paused_at timestamptz,
  add column if not exists customer_paused_by uuid references auth.users(id);

create table if not exists pace_v2.country_customer_availability_audit(
  id uuid primary key default gen_random_uuid(),
  country_id uuid not null references pace_v2.countries(id),
  paused boolean not null,
  reason text not null check(length(trim(reason))>0),
  changed_by uuid not null references auth.users(id),
  changed_at timestamptz not null default now()
);
create index if not exists country_customer_availability_audit_country_idx
  on pace_v2.country_customer_availability_audit(country_id,changed_at desc);
alter table pace_v2.country_customer_availability_audit enable row level security;
drop policy if exists country_customer_availability_audit_admin_read on pace_v2.country_customer_availability_audit;
create policy country_customer_availability_audit_admin_read on pace_v2.country_customer_availability_audit for select to authenticated using (pace_v2.is_site_admin());
revoke all on pace_v2.country_customer_availability_audit from public,anon,authenticated;
grant select on pace_v2.country_customer_availability_audit to authenticated;

create or replace function public.v2_admin_set_country_customer_availability(p_country_id uuid,p_paused boolean,p_reason text)
returns void language plpgsql security definer set search_path=''
as $$
declare v_reason text:=trim(coalesce(p_reason,''));
begin
  if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
  if v_reason='' then raise exception 'Reason is required'; end if;
  update pace_v2.countries set
    customer_availability_paused=coalesce(p_paused,false),customer_pause_reason=v_reason,
    customer_paused_at=now(),customer_paused_by=auth.uid(),updated_at=now()
  where id=p_country_id;
  if not found then raise exception 'country not found'; end if;
  insert into pace_v2.country_customer_availability_audit(country_id,paused,reason,changed_by)
  values(p_country_id,coalesce(p_paused,false),v_reason,auth.uid());
end $$;
revoke all on function public.v2_admin_set_country_customer_availability(uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.v2_admin_set_country_customer_availability(uuid,boolean,text) to authenticated;

create or replace view public.v2_countries as
select id,name,code,description,picture_url,hero_image_url,timezone,is_large,region_label,locality_label,active,display_order,created_at,updated_at,blurb,picture_url_backup,charity_name,charity_description,charity_url,v1_source_ids,
 customer_availability_paused,customer_pause_reason,customer_paused_at,customer_paused_by
from pace_v2.countries where pace_v2.is_site_admin();

create or replace view public.v2_public_countries as
select id,name,code,description,blurb,picture_url,hero_image_url,timezone,is_large,region_label,locality_label,display_order
from pace_v2.countries c where active and customer_availability_paused is not true and name<>'United States of America';
create or replace view public.v2_public_destinations as
select d.id,d.country_id,d.name,d.town,d.region,d.picture_url,d.description,d.wet_or_dry,d.url,d.gift,d.arrival_notes,d.region_id,d.locality_id,d.sort_order,d.address1,d.address2,d.postal_code,d.phone,d.destination_type,d.email,d.directions_url,d.latitude,d.longitude
from pace_v2.destinations d join pace_v2.countries c on c.id=d.country_id
where d.active and d.published_at is not null and c.active and c.customer_availability_paused is not true;
create or replace view public.v2_public_pickups as
select p.id,p.country_id,p.name,p.town,p.region,p.picture_url,p.description,p.arrival_notes,p.directions_url,p.region_id,p.locality_id,p.sort_order,p.address1,p.address2,p.postal_code,p.latitude,p.longitude
from pace_v2.pickup_points p join pace_v2.countries c on c.id=p.country_id
where p.active and c.active and c.customer_availability_paused is not true;

create or replace view public.v2_public_departures as
with eligible as(
 select d.id departure_id,v.vehicle_type_id
 from pace_v2.departures d
 join pace_v2.routes r on r.id=d.route_id and r.is_active
 join pace_v2.countries c on c.id=r.country_id and c.active and c.customer_availability_paused is not true
 join pace_v2.destinations dst on dst.id=r.destination_id and dst.active and dst.published_at is not null
 join pace_v2.vehicle_route_offers vro on vro.service_id=d.service_id and vro.active and vro.effective_from<=d.scheduled_departure_ts and (vro.effective_to is null or vro.effective_to>d.scheduled_departure_ts)
 join pace_v2.vehicles v on v.id=vro.vehicle_id and v.active
 join pace_v2.operators o on o.id=v.operator_id and o.active
 join pace_v2.operator_vehicle_types ovt on ovt.operator_id=v.operator_id and ovt.vehicle_type_id=v.vehicle_type_id and ovt.status='approved'
 join pace_v2.route_vehicle_types rvt on rvt.route_id=d.route_id and rvt.vehicle_type_id=v.vehicle_type_id and rvt.active and rvt.effective_from<=d.scheduled_departure_ts and (rvt.effective_to is null or rvt.effective_to>d.scheduled_departure_ts)
 where d.scheduled_departure_ts>now() and d.status in('scheduled','selling','at_risk','under_consideration')
 and not exists(select 1 from pace_v2.vehicle_availability_exceptions vae where vae.vehicle_id=v.id and vae.start_ts<coalesce(d.scheduled_arrival_ts,d.scheduled_departure_ts+interval '8 hours') and vae.end_ts>d.scheduled_departure_ts)
 group by d.id,v.vehicle_type_id
), types as(
 select e.departure_id,jsonb_agg(jsonb_build_object('id',vt.id,'name',vt.name,'picture_url',vt.picture_url) order by vt.name) vehicle_types
 from eligible e join pace_v2.vehicle_types vt on vt.id=e.vehicle_type_id and vt.active group by e.departure_id
)
select d.id departure_id,d.route_id,r.route_name,r.country_id,r.pickup_id,r.destination_id,r.approx_duration_mins,r.trip_timezone,r.picture_url route_picture_url,r.display_description,d.scheduled_departure_ts,d.scheduled_arrival_ts,d.local_departure_date,d.status,d.t72_ts,d.t24_ts,p.name pickup_name,p.picture_url pickup_picture_url,p.description pickup_description,dst.name destination_name,dst.picture_url destination_picture_url,dst.description destination_description,dst.wet_or_dry,t.vehicle_types
from types t join pace_v2.departures d on d.id=t.departure_id join pace_v2.routes r on r.id=d.route_id join pace_v2.pickup_points p on p.id=r.pickup_id and p.active join pace_v2.destinations dst on dst.id=r.destination_id and dst.active and dst.published_at is not null;

create or replace function public.v2_public_quote(p_departure_id uuid,p_party_size integer)
returns table(result_status text,departure_id uuid,route_id uuid,route_name text,pickup_name text,destination_name text,scheduled_departure_ts timestamptz,trip_timezone text,vehicle_consideration_id uuid,vehicle_id uuid,vehicle_name text,operator_id uuid,operator_name text,allocation_stage text,net_unit_price_cents integer,tax_cents integer,fee_cents integer,all_in_unit_price_cents integer,all_in_total_cents integer,currency text,discount_applied boolean,discount_bps integer,quality_score numeric,max_party_size integer,quote_expires_at timestamptz)
language plpgsql security definer set search_path='public','pace_v2' as $$
declare offer record;dep record;tf record;v_tax integer:=0;v_fee integer:=0;v_tax_cents integer;v_fee_cents integer;v_allin integer;v_max integer;v_expiry timestamptz;
begin
 if p_party_size is null or p_party_size<1 or p_party_size>50 then raise exception 'Party size must be between 1 and 50';end if;
 select d.id,d.route_id,r.route_name,r.country_id,p.name pickup_name,dst.name destination_name,d.scheduled_departure_ts,d.trip_timezone,d.t24_ts into dep
 from pace_v2.departures d join pace_v2.routes r on r.id=d.route_id and r.is_active join pace_v2.countries c on c.id=r.country_id and c.active and c.customer_availability_paused is not true join pace_v2.pickup_points p on p.id=r.pickup_id and p.active join pace_v2.destinations dst on dst.id=r.destination_id and dst.active and dst.published_at is not null
 where d.id=p_departure_id and d.scheduled_departure_ts>now() and d.t24_ts>now() and d.status in('scheduled','selling','at_risk','under_consideration');
 if dep.id is null then raise exception 'Journey is not currently available for booking';end if;
 v_expiry:=least(dep.t24_ts,now()+interval '15 minutes');select * into offer from pace_v2.get_live_party_offer(p_departure_id,p_party_size);
 if offer.result_status<>'offer' then return query select offer.result_status,dep.id,dep.route_id,dep.route_name,dep.pickup_name,dep.destination_name,dep.scheduled_departure_ts,dep.trip_timezone,offer.vehicle_consideration_id,offer.vehicle_id,offer.vehicle_name,offer.operator_id,offer.operator_name,offer.allocation_stage,coalesce(offer.offered_price_cents,0),0,0,0,0,'USD',coalesce(offer.discount_applied,false),coalesce(offer.discount_bps,0),offer.quality_score,0,v_expiry;return;end if;
 select ctf.tax_bps,ctf.customer_fee_bps into tf from pace_v2.country_tax_fees ctf where ctf.country_id=dep.country_id and ctf.effective_from<=now() and (ctf.effective_to is null or ctf.effective_to>now()) order by ctf.effective_from desc limit 1;
 v_tax:=coalesce(tf.tax_bps,0);v_fee:=coalesce(tf.customer_fee_bps,0);v_tax_cents:=round(offer.offered_price_cents*v_tax/10000.0);v_fee_cents:=round((offer.offered_price_cents+v_tax_cents)*v_fee/10000.0);v_allin:=offer.offered_price_cents+v_tax_cents+v_fee_cents;
 select greatest(coalesce(max(vc.max_seats-vc.assigned_seats),0),p_party_size) into v_max from pace_v2.vehicle_considerations vc where vc.departure_id=p_departure_id and vc.status in('eligible','open','filling_minimum','minimum_achieved','under_consideration');
 return query select 'offer',dep.id,dep.route_id,dep.route_name,dep.pickup_name,dep.destination_name,dep.scheduled_departure_ts,dep.trip_timezone,offer.vehicle_consideration_id,offer.vehicle_id,offer.vehicle_name,offer.operator_id,offer.operator_name,offer.allocation_stage,offer.offered_price_cents,v_tax_cents,v_fee_cents,v_allin,v_allin*p_party_size,'USD',offer.discount_applied,offer.discount_bps,offer.quality_score,coalesce(v_max,p_party_size),v_expiry;
end $$;

-- Replace the partner function from the optimized catalogue migration, adding the same country pause guard.
create or replace function public.v2_system_partner_shuttle_catalog(p_api_key text) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_partner pace_v2.api_partners%rowtype;v_recent_requests integer;v_tiles jsonb;
begin
 if nullif(trim(coalesce(p_api_key,'')),'') is null then return jsonb_build_object('authorized',false);end if;
 select * into v_partner from pace_v2.api_partners where api_key_hash=encode(extensions.digest(p_api_key,'sha256'),'hex') and active limit 1 for update;
 if v_partner.id is null then return jsonb_build_object('authorized',false);end if;
 select count(*) into v_recent_requests from pace_v2.partner_api_requests where partner_id=v_partner.id and requested_at>=now()-interval '1 minute';
 if v_recent_requests>=v_partner.rate_limit_per_minute then return jsonb_build_object('authorized',true,'rate_limited',true);end if;
 insert into pace_v2.partner_api_requests(partner_id) values(v_partner.id);update pace_v2.api_partners set last_used_at=now(),updated_at=now() where id=v_partner.id;
 with viable as(
  select distinct on(d.route_id) d.route_id,d.scheduled_departure_ts,v.vehicle_type_id
  from pace_v2.departures d join pace_v2.routes r on r.id=d.route_id and r.is_active and r.country_id=v_partner.country_id
  join pace_v2.countries c on c.id=r.country_id and c.active and c.customer_availability_paused is not true
  join pace_v2.vehicle_route_offers vro on vro.service_id=d.service_id and vro.active and vro.effective_from<=d.scheduled_departure_ts and (vro.effective_to is null or vro.effective_to>d.scheduled_departure_ts)
  join pace_v2.vehicles v on v.id=vro.vehicle_id and v.active join pace_v2.operators o on o.id=v.operator_id and o.active
  join pace_v2.operator_vehicle_types ovt on ovt.operator_id=v.operator_id and ovt.vehicle_type_id=v.vehicle_type_id and ovt.status='approved'
  join pace_v2.route_vehicle_types rvt on rvt.route_id=d.route_id and rvt.vehicle_type_id=v.vehicle_type_id and rvt.active and rvt.effective_from<=d.scheduled_departure_ts and (rvt.effective_to is null or rvt.effective_to>d.scheduled_departure_ts)
  where d.scheduled_departure_ts>now() and d.status in('scheduled','selling','at_risk','under_consideration') and not exists(select 1 from pace_v2.vehicle_availability_exceptions vae where vae.vehicle_id=v.id and vae.start_ts<coalesce(d.scheduled_arrival_ts,d.scheduled_departure_ts+interval '8 hours') and vae.end_ts>d.scheduled_departure_ts)
  order by d.route_id,d.scheduled_departure_ts,v.vehicle_type_id
 )
 select coalesce(jsonb_agg(tile order by tile->>'route_name'),'[]'::jsonb) into v_tiles from(
  select jsonb_build_object('route_id',r.id,'country',c.name,'vehicle_type',vt.name,'route_name',r.route_name,'pickup',jsonb_build_object('id',p.id,'name',p.name,'image_url',p.picture_url),'destination',jsonb_build_object('id',dst.id,'name',dst.name,'image_url',dst.picture_url),'schedule',nullif(trim(coalesce(r.frequency,'')),'')) tile
  from viable join pace_v2.routes r on r.id=viable.route_id and r.is_active join pace_v2.countries c on c.id=r.country_id and c.active and c.customer_availability_paused is not true join pace_v2.pickup_points p on p.id=r.pickup_id and p.active join pace_v2.destinations dst on dst.id=r.destination_id and dst.active and dst.published_at is not null join pace_v2.vehicle_types vt on vt.id=viable.vehicle_type_id and vt.active
 ) catalogue;
 return jsonb_build_object('authorized',true,'partner',jsonb_build_object('id',v_partner.id,'name',v_partner.name),'country_id',v_partner.country_id,'tiles',v_tiles);
end $$;
revoke all on function public.v2_system_partner_shuttle_catalog(text) from public,anon,authenticated;
grant execute on function public.v2_system_partner_shuttle_catalog(text) to service_role;
