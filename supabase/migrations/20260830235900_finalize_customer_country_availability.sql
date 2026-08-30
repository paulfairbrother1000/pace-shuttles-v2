-- Final definitions intentionally sort after all 2026083022xxxx partner API migrations.
create or replace function public.v2_customer_commit_quote(p_quote_id uuid,p_customer_name text,p_customer_email text,p_lead_last_name text,p_passengers jsonb default '[]'::jsonb)
returns table(order_id uuid,booking_id uuid,departure_id uuid,route_name text,scheduled_departure_ts timestamptz,party_size integer,subtotal_cents integer,taxes_cents integer,fees_cents integer,total_cents integer,currency text,payment_status text)
language plpgsql security definer set search_path='public','pace_v2','auth' as $$
declare qi pace_v2.quote_intents%rowtype;dep record;v_order uuid;v_booking uuid;v_sub integer;v_tax integer;v_fees integer;v_total integer;item jsonb;v_net_unit integer;v_tax_unit integer;v_fee_unit integer;
begin
 if auth.uid() is null then raise exception 'sign in required';end if;
 if trim(coalesce(p_customer_name,''))='' or trim(coalesce(p_customer_email,''))='' then raise exception 'customer name and email required';end if;
 select * into qi from pace_v2.quote_intents where id=p_quote_id for update;
 if not found or qi.expires_at<=now() then raise exception 'quote has expired; please choose the journey again';end if;
 select d.id,d.route_id,d.scheduled_departure_ts,r.route_name into dep
 from pace_v2.departures d join pace_v2.routes r on r.id=d.route_id and r.is_active
 join pace_v2.countries c on c.id=r.country_id and c.active and c.customer_availability_paused is not true
 where d.id=qi.departure_id and d.status not in('cancelled','completed') for share of c;
 if dep.id is null then raise exception 'journey is no longer available';end if;
 v_net_unit:=coalesce((qi.quote_snapshot->>'net_unit_price_cents')::integer,qi.unit_price_cents);v_tax_unit:=coalesce((qi.quote_snapshot->>'tax_cents')::integer,0);v_fee_unit:=coalesce((qi.quote_snapshot->>'fee_cents')::integer,0);v_sub:=v_net_unit*qi.party_size;v_tax:=v_tax_unit*qi.party_size;v_fees:=v_fee_unit*qi.party_size;v_total:=qi.total_price_cents;
 insert into pace_v2.orders(customer_user_id,customer_email,customer_name,currency,subtotal_cents,tax_rate_bps,customer_fee_rate_bps,taxes_cents,fees_cents,total_cents,payment_status) values(auth.uid(),lower(trim(p_customer_email)),trim(p_customer_name),'USD',v_sub,0,0,v_tax,v_fees,v_total,'pending') returning id into v_order;
 insert into pace_v2.bookings(order_id,departure_id,route_id,quote_intent_id,customer_name,lead_last_name,seats,status,currency,unit_price_cents,total_price_cents,commercial_snapshot) values(v_order,qi.departure_id,dep.route_id,qi.id,trim(p_customer_name),nullif(trim(coalesce(p_lead_last_name,'')),''),qi.party_size,'pending_payment','USD',v_net_unit,v_sub,jsonb_build_object('payment_required_before_allocation',true,'quote_snapshot',qi.quote_snapshot,'customer_all_in_total_cents',v_total,'taxes_cents',v_tax,'fees_cents',v_fees)) returning id into v_booking;
 if jsonb_typeof(p_passengers)='array' then for item in select * from jsonb_array_elements(p_passengers) loop if trim(coalesce(item->>'first_name',''))<>'' then insert into pace_v2.passengers(booking_id,first_name,last_name,age_group,email,phone,notes) values(v_booking,trim(item->>'first_name'),nullif(trim(coalesce(item->>'last_name','')),''),coalesce(nullif(trim(coalesce(item->>'age_group','')),''),'adult'),nullif(trim(coalesce(item->>'email','')),''),nullif(trim(coalesce(item->>'phone','')),''),nullif(trim(coalesce(item->>'notes','')),''));end if;end loop;end if;
 return query select v_order,v_booking,dep.id,dep.route_name,dep.scheduled_departure_ts,qi.party_size,v_sub,v_tax,v_fees,v_total,'USD','pending';
end $$;

create or replace function public.v2_customer_order_payment_context(p_order_id uuid)
returns table(order_id uuid,booking_id uuid,departure_id uuid,route_name text,pickup_name text,destination_name text,scheduled_departure_ts timestamptz,seats integer,subtotal_cents integer,taxes_cents integer,fees_cents integer,total_cents integer,currency text,payment_status text,provider_checkout_ref text,country_id uuid,country_name text,terms_id uuid,terms_version text,terms_accepted boolean)
language plpgsql security definer set search_path='public','pace_v2','auth' as $$
begin
 if auth.uid() is null then raise exception 'sign in required';end if;
 if exists(select 1 from pace_v2.orders o join pace_v2.bookings b on b.order_id=o.id join pace_v2.routes r on r.id=b.route_id join pace_v2.countries c on c.id=r.country_id where o.id=p_order_id and o.customer_user_id=auth.uid() and o.payment_status<>'paid' and c.customer_availability_paused) then raise exception 'New bookings in this country are temporarily paused';end if;
 return query select o.id,b.id,b.departure_id,r.route_name,p.name,dst.name,dp.scheduled_departure_ts,b.seats,o.subtotal_cents,o.taxes_cents,o.fees_cents,o.total_cents,o.currency,o.payment_status::text,o.provider_checkout_ref,c.id,c.name,t.id,t.version,true
 from pace_v2.orders o join pace_v2.bookings b on b.order_id=o.id join pace_v2.departures dp on dp.id=b.departure_id join pace_v2.routes r on r.id=b.route_id join pace_v2.pickup_points p on p.id=r.pickup_id join pace_v2.destinations dst on dst.id=r.destination_id join pace_v2.countries c on c.id=r.country_id and c.active and (o.payment_status='paid' or c.customer_availability_paused is not true) join pace_v2.country_terms t on t.country_id=c.id and t.is_active=true join pace_v2.order_terms_acceptance a on a.order_id=o.id and a.country_terms_id=t.id
 where o.id=p_order_id and o.customer_user_id=auth.uid() order by t.effective_from desc limit 1;
 if not found then if exists(select 1 from pace_v2.orders o where o.id=p_order_id and o.customer_user_id=auth.uid()) then raise exception 'You must accept the current country Terms & Conditions before payment.';else raise exception 'order not found';end if;end if;
end $$;

create or replace function public.v2_system_mark_stripe_paid(p_order_id uuid,p_session_id text,p_payment_intent_id text,p_charge_id text default null,p_payload jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path='public','pace_v2' as $$
declare b_id uuid;amt integer;curr text;current_fulfillment text;country_paused boolean;alloc record;rr_id uuid;
begin
 select b.id,o.total_cents,o.currency,o.fulfillment_status,c.customer_availability_paused into b_id,amt,curr,current_fulfillment,country_paused
 from pace_v2.orders o join pace_v2.bookings b on b.order_id=o.id join pace_v2.routes r on r.id=b.route_id join pace_v2.countries c on c.id=r.country_id where o.id=p_order_id for update of o,b for share of c;
 if b_id is null then raise exception 'order not found';end if;
 update pace_v2.payment_transactions set status='paid',stripe_payment_intent_id=coalesce(nullif(p_payment_intent_id,''),stripe_payment_intent_id),stripe_charge_id=coalesce(nullif(p_charge_id,''),stripe_charge_id),raw_provider_status=coalesce(raw_provider_status,'{}'::jsonb)||coalesce(p_payload,'{}'::jsonb),completed_at=coalesce(completed_at,now()) where order_id=p_order_id and provider_name='stripe' and (provider_reference=p_session_id or stripe_payment_intent_id=p_payment_intent_id);
 if current_fulfillment in('booked','refund_required','refunded') then return;end if;
 update pace_v2.orders set payment_status='paid',fulfillment_status=case when country_paused then 'refund_required' else 'allocating' end,provider_checkout_ref=coalesce(nullif(p_session_id,''),provider_checkout_ref),paid_at=coalesce(paid_at,now()) where id=p_order_id;
 if not country_paused then select * into alloc from pace_v2.allocate_paid_booking(b_id);end if;
 if not country_paused and alloc.result_status='allocated' then update pace_v2.orders set fulfillment_status='booked' where id=p_order_id;return;end if;
 update pace_v2.bookings set status='cancelled',updated_at=now(),commercial_snapshot=coalesce(commercial_snapshot,'{}'::jsonb)||jsonb_build_object('post_payment_allocation_failed',true,'allocation_result',case when country_paused then 'country_paused' else alloc.result_status end) where id=b_id;
 select id into rr_id from pace_v2.refund_requests where booking_id=b_id and status in('requested','approved') order by requested_at desc limit 1;
 if rr_id is null then insert into pace_v2.refund_requests(booking_id,order_id,currency,requested_refund_cents,approved_refund_cents,status,reason,requested_by,requested_at,approved_at) values(b_id,p_order_id,curr,amt,amt,'approved',case when country_paused then 'Automatic full refund: Emergency country pause prevented booking completion' else 'Automatic full refund: payment succeeded but whole-party capacity was no longer available' end,'system',now(),now()) returning id into rr_id;end if;
 update pace_v2.orders set fulfillment_status='refund_required' where id=p_order_id;
end $$;

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


create or replace view public.v2_public_countries as
select id,name,code,description,blurb,picture_url,hero_image_url,timezone,is_large,region_label,locality_label,display_order
from pace_v2.countries c
where c.active and c.customer_availability_paused is not true and c.name<>'United States of America'
and exists(select 1 from public.v2_public_departures d where d.country_id=c.id);

create or replace view public.v2_public_destinations as
select d.id,d.country_id,d.name,d.town,d.region,d.picture_url,d.description,d.wet_or_dry,d.url,d.gift,d.arrival_notes,d.region_id,d.locality_id,d.sort_order,d.address1,d.address2,d.postal_code,d.phone,d.destination_type,d.email,d.directions_url,d.latitude,d.longitude
from pace_v2.destinations d join pace_v2.countries c on c.id=d.country_id
where d.active and d.published_at is not null and c.active and c.customer_availability_paused is not true
and exists(select 1 from public.v2_public_departures dep where dep.destination_id=d.id);

create or replace view public.v2_public_pickups as
select p.id,p.country_id,p.name,p.town,p.region,p.picture_url,p.description,p.arrival_notes,p.directions_url,p.region_id,p.locality_id,p.sort_order,p.address1,p.address2,p.postal_code,p.latitude,p.longitude
from pace_v2.pickup_points p join pace_v2.countries c on c.id=p.country_id
where p.active and c.active and c.customer_availability_paused is not true
and exists(select 1 from public.v2_public_departures dep where dep.pickup_id=p.id);

