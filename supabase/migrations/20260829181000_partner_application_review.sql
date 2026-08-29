create or replace view public.v2_admin_partner_applications as
select
 a.*,
 c.name as country_name,
 vt.name as transport_type_name,
 dt.type as destination_type_name,
 coalesce((select array_agg(pap.place_id order by pap.place_id) from pace_v2.partner_application_places pap where pap.application_id=a.id),'{}'::uuid[]) as place_ids
from pace_v2.partner_applications a
left join pace_v2.countries c on c.id=a.country_id
left join pace_v2.vehicle_types vt on vt.id=a.transport_type_id
left join pace_v2.destination_types dt on dt.id=a.destination_type_id
where pace_v2.is_site_admin();

revoke all on public.v2_admin_partner_applications from public,anon,authenticated;
grant select on public.v2_admin_partner_applications to authenticated;

create or replace function public.v2_admin_update_partner_application(p_application_id uuid,p_changes jsonb)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 v_app pace_v2.partner_applications%rowtype;
 v_country_id uuid;
 v_transport_type_id uuid;
 v_destination_type_id bigint;
 v_place_count integer;
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 select * into v_app from pace_v2.partner_applications where id=p_application_id for update;
 if v_app.id is null then raise exception 'application not found'; end if;
 if v_app.status='approved' then raise exception 'approved applications must be edited through the linked record'; end if;

 begin
  v_country_id:=case when p_changes ? 'country_id' then nullif(p_changes->>'country_id','')::uuid else v_app.country_id end;
  v_transport_type_id:=case when p_changes ? 'transport_type_id' then nullif(p_changes->>'transport_type_id','')::uuid else v_app.transport_type_id end;
  v_destination_type_id:=case when p_changes ? 'destination_type_id' then nullif(p_changes->>'destination_type_id','')::bigint else v_app.destination_type_id end;
 exception when invalid_text_representation then
  raise exception using errcode='22023',message='application contains an invalid identifier';
 end;

 update pace_v2.partner_applications a set
  country_id=case when p_changes ? 'other_country_text' and nullif(trim(coalesce(p_changes->>'other_country_text','')),'') is not null then null else v_country_id end,
  other_country_text=case
   when p_changes ? 'country_id' and v_country_id is not null then null
   when p_changes ? 'other_country_text' then nullif(trim(coalesce(p_changes->>'other_country_text','')),'')
   else a.other_country_text end,
  org_name=case when p_changes ? 'org_name' then nullif(trim(coalesce(p_changes->>'org_name','')),'') else a.org_name end,
  org_address=case when p_changes ? 'org_address' then nullif(trim(coalesce(p_changes->>'org_address','')),'') else a.org_address end,
  telephone=case when p_changes ? 'telephone' then nullif(trim(coalesce(p_changes->>'telephone','')),'') else a.telephone end,
  mobile=case when p_changes ? 'mobile' then nullif(trim(coalesce(p_changes->>'mobile','')),'') else a.mobile end,
  email=case when p_changes ? 'email' then nullif(lower(trim(coalesce(p_changes->>'email',''))),'') else a.email end,
  website=case when p_changes ? 'website' then nullif(trim(coalesce(p_changes->>'website','')),'') else a.website end,
  social_instagram=case when p_changes ? 'social_instagram' then nullif(trim(coalesce(p_changes->>'social_instagram','')),'') else a.social_instagram end,
  social_youtube=case when p_changes ? 'social_youtube' then nullif(trim(coalesce(p_changes->>'social_youtube','')),'') else a.social_youtube end,
  social_x=case when p_changes ? 'social_x' then nullif(trim(coalesce(p_changes->>'social_x','')),'') else a.social_x end,
  social_facebook=case when p_changes ? 'social_facebook' then nullif(trim(coalesce(p_changes->>'social_facebook','')),'') else a.social_facebook end,
  contact_name=case when p_changes ? 'contact_name' then nullif(trim(coalesce(p_changes->>'contact_name','')),'') else a.contact_name end,
  contact_role=case when p_changes ? 'contact_role' then nullif(trim(coalesce(p_changes->>'contact_role','')),'') else a.contact_role end,
  years_operation=case when p_changes ? 'years_operation' then nullif(p_changes->>'years_operation','')::integer else a.years_operation end,
  transport_type_id=v_transport_type_id,
  fleet_size=case when p_changes ? 'fleet_size' then nullif(p_changes->>'fleet_size','')::integer else a.fleet_size end,
  destination_type_id=v_destination_type_id,
  pickup_suggestions=case when p_changes ? 'pickup_suggestions' then nullif(trim(coalesce(p_changes->>'pickup_suggestions','')),'') else a.pickup_suggestions end,
  destination_suggestions=case when p_changes ? 'destination_suggestions' then nullif(trim(coalesce(p_changes->>'destination_suggestions','')),'') else a.destination_suggestions end,
  description=case when p_changes ? 'description' then nullif(trim(coalesce(p_changes->>'description','')),'') else a.description end,
  admin_notes=case when p_changes ? 'admin_notes' then nullif(trim(coalesce(p_changes->>'admin_notes','')),'') else a.admin_notes end,
  reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now()
 where a.id=p_application_id
 returning * into v_app;

 if v_app.country_id is not null and not exists(select 1 from pace_v2.countries where id=v_app.country_id) then raise exception 'country not found'; end if;
 if v_app.application_type='operator' and not exists(select 1 from pace_v2.vehicle_types where id=v_app.transport_type_id and active) then raise exception 'transport type not found or inactive'; end if;
 if v_app.application_type='destination' and not exists(select 1 from pace_v2.destination_types where id=v_app.destination_type_id and active) then raise exception 'destination type not found or inactive'; end if;

 if p_changes ? 'place_ids' then
  delete from pace_v2.partner_application_places where application_id=p_application_id;
  if v_app.application_type<>'operator' and jsonb_array_length(coalesce(p_changes->'place_ids','[]'::jsonb))>0 then raise exception 'places apply only to operators'; end if;
  if jsonb_typeof(coalesce(p_changes->'place_ids','[]'::jsonb))<>'array' then raise exception 'place_ids must be an array'; end if;
  select count(*) into v_place_count from jsonb_array_elements_text(coalesce(p_changes->'place_ids','[]'::jsonb));
  if v_place_count>50 then raise exception 'too many supported places'; end if;
  if exists(select 1 from jsonb_array_elements_text(coalesce(p_changes->'place_ids','[]'::jsonb)) j(value)
    left join pace_v2.transport_type_places p on p.id=j.value::uuid
    where p.id is null or not p.active or p.transport_type_id<>v_app.transport_type_id)
  then raise exception 'a supported place is invalid for the transport type'; end if;
  insert into pace_v2.partner_application_places(application_id,place_id)
  select p_application_id,j.value::uuid from jsonb_array_elements_text(coalesce(p_changes->'place_ids','[]'::jsonb)) j(value)
  on conflict do nothing;
 end if;
 return p_application_id;
exception when check_violation then
 raise exception using errcode='22023',message='application contains an invalid or overlong value';
end
$$;

create or replace function public.v2_admin_set_partner_application_status(p_application_id uuid,p_status text,p_admin_notes text default null)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare v_current text;
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 if p_status not in ('under_review','rejected') then raise exception 'use approval action to approve an application'; end if;
 select status into v_current from pace_v2.partner_applications where id=p_application_id for update;
 if v_current is null then raise exception 'application not found'; end if;
 if v_current='approved' then raise exception 'approved application status cannot be changed'; end if;
 if v_current='rejected' and p_status<>'under_review' then raise exception 'rejected application must be reconsidered before another decision'; end if;
 update pace_v2.partner_applications set status=p_status,
  admin_notes=coalesce(nullif(trim(coalesce(p_admin_notes,'')),''),admin_notes),
  reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now()
 where id=p_application_id;
 return p_application_id;
end
$$;

create or replace function public.v2_admin_approve_partner_application(p_application_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
 v_app pace_v2.partner_applications%rowtype;
 v_operator_id uuid;
 v_destination_id uuid;
 v_destination_type text;
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;
 select * into v_app from pace_v2.partner_applications where id=p_application_id for update;
 if v_app.id is null then raise exception 'application not found'; end if;
 if v_app.status='approved' then
  return jsonb_build_object('application_id',v_app.id,'application_type',v_app.application_type,
   'operator_id',v_app.operator_id,'destination_id',v_app.destination_id,'status','approved');
 end if;
 if v_app.status not in ('new','under_review') then raise exception 'reconsider rejected application before approval'; end if;
 if v_app.country_id is null then raise exception 'assign a supported country before approval'; end if;

 if v_app.application_type='operator' then
  if nullif(trim(coalesce(v_app.email,'')),'') is null then raise exception 'operator admin email is required before approval'; end if;
  insert into pace_v2.operators(name,country_id,admin_email,email,contact_email,notification_email,phone,address1,active)
  values(v_app.org_name,v_app.country_id,lower(v_app.email),lower(v_app.email),lower(v_app.email),lower(v_app.email),
   coalesce(v_app.telephone,v_app.mobile),v_app.org_address,false)
  returning id into v_operator_id;
  insert into pace_v2.operator_vehicle_types(operator_id,vehicle_type_id,status,approved_at,approved_by,note)
  values(v_operator_id,v_app.transport_type_id,'approved',now(),auth.uid(),'Approved partner application '||v_app.id::text)
  on conflict(operator_id,vehicle_type_id) do update set status='approved',approved_at=now(),approved_by=auth.uid(),suspended_at=null,updated_at=now();
 else
  select type into v_destination_type from pace_v2.destination_types where id=v_app.destination_type_id and active;
  if v_destination_type is null then raise exception 'destination type not found or inactive'; end if;
  insert into pace_v2.destinations(country_id,name,address1,phone,description,destination_type,url,email,active)
  values(v_app.country_id,v_app.org_name,v_app.org_address,coalesce(v_app.telephone,v_app.mobile),v_app.description,
   v_destination_type,v_app.website,v_app.email,false)
  returning id into v_destination_id;
 end if;

 update pace_v2.partner_applications set status='approved',reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now(),
  operator_id=v_operator_id,destination_id=v_destination_id
 where id=v_app.id;

 return jsonb_build_object('application_id',v_app.id,'application_type',v_app.application_type,
  'operator_id',v_operator_id,'destination_id',v_destination_id,'status','approved');
end
$$;

revoke all on function public.v2_admin_update_partner_application(uuid,jsonb) from public,anon;
revoke all on function public.v2_admin_set_partner_application_status(uuid,text,text) from public,anon;
revoke all on function public.v2_admin_approve_partner_application(uuid) from public,anon;
grant execute on function public.v2_admin_update_partner_application(uuid,jsonb) to authenticated;
grant execute on function public.v2_admin_set_partner_application_status(uuid,text,text) to authenticated;
grant execute on function public.v2_admin_approve_partner_application(uuid) to authenticated;
