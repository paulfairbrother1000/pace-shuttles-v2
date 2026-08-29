create table pace_v2.partner_applications (
 id uuid primary key default gen_random_uuid(),
 application_type text not null check (application_type in ('operator','destination')),
 status text not null default 'new' check (status in ('new','under_review','approved','rejected')),
 country_id uuid references pace_v2.countries(id),
 other_country_text text check (other_country_text is null or char_length(other_country_text)<=120),
 org_name text not null check (char_length(org_name) between 1 and 200),
 org_address text check (org_address is null or char_length(org_address)<=1000),
 telephone text check (telephone is null or char_length(telephone)<=80),
 mobile text check (mobile is null or char_length(mobile)<=80),
 email text check (email is null or char_length(email)<=320),
 website text check (website is null or char_length(website)<=500),
 social_instagram text check (social_instagram is null or char_length(social_instagram)<=500),
 social_youtube text check (social_youtube is null or char_length(social_youtube)<=500),
 social_x text check (social_x is null or char_length(social_x)<=500),
 social_facebook text check (social_facebook is null or char_length(social_facebook)<=500),
 contact_name text check (contact_name is null or char_length(contact_name)<=200),
 contact_role text check (contact_role is null or char_length(contact_role)<=200),
 years_operation integer check (years_operation is null or years_operation between 0 and 500),
 transport_type_id uuid references pace_v2.vehicle_types(id),
 fleet_size integer check (fleet_size is null or fleet_size>=0),
 destination_type_id bigint references pace_v2.destination_types(id),
 pickup_suggestions text check (pickup_suggestions is null or char_length(pickup_suggestions)<=4000),
 destination_suggestions text check (destination_suggestions is null or char_length(destination_suggestions)<=4000),
 description text check (description is null or char_length(description)<=8000),
 admin_notes text check (admin_notes is null or char_length(admin_notes)<=8000),
 submitted_by uuid references auth.users(id),
 reviewed_by uuid references auth.users(id),
 reviewed_at timestamptz,
 operator_id uuid references pace_v2.operators(id),
 destination_id uuid references pace_v2.destinations(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint partner_application_country_check check (
  (country_id is not null and other_country_text is null)
  or (country_id is null and nullif(trim(other_country_text),'') is not null)
 ),
 constraint partner_application_type_fields_check check (
  (application_type='operator' and transport_type_id is not null and destination_type_id is null)
  or (application_type='destination' and destination_type_id is not null and transport_type_id is null and fleet_size is null)
 ),
 constraint partner_application_promotion_type_check check (
  (operator_id is null or application_type='operator')
  and (destination_id is null or application_type='destination')
  and not (operator_id is not null and destination_id is not null)
 )
);

create index partner_applications_status_created_idx
 on pace_v2.partner_applications(status,created_at desc);
create index partner_applications_type_status_idx
 on pace_v2.partner_applications(application_type,status);

create table pace_v2.partner_application_places (
 application_id uuid not null references pace_v2.partner_applications(id) on delete cascade,
 place_id uuid not null references pace_v2.transport_type_places(id),
 created_at timestamptz not null default now(),
 primary key(application_id,place_id)
);

alter table pace_v2.partner_applications enable row level security;
alter table pace_v2.partner_application_places enable row level security;

revoke all on pace_v2.partner_applications from public,anon,authenticated;
revoke all on pace_v2.partner_application_places from public,anon,authenticated;

create or replace view public.v2_public_partner_form_countries as
select id,name
from pace_v2.countries
where active;

create or replace view public.v2_public_partner_form_transport_types as
select id,name,description,picture_url,display_order
from pace_v2.vehicle_types
where active;

create or replace view public.v2_public_partner_form_destination_types as
select id,type,description,display_order
from pace_v2.destination_types
where active;

create or replace view public.v2_public_partner_form_places as
select id,transport_type_id,name,description
from pace_v2.transport_type_places
where active;

revoke all on public.v2_public_partner_form_countries from public,anon,authenticated;
revoke all on public.v2_public_partner_form_transport_types from public,anon,authenticated;
revoke all on public.v2_public_partner_form_destination_types from public,anon,authenticated;
revoke all on public.v2_public_partner_form_places from public,anon,authenticated;
grant select on public.v2_public_partner_form_countries to anon,authenticated;
grant select on public.v2_public_partner_form_transport_types to anon,authenticated;
grant select on public.v2_public_partner_form_destination_types to anon,authenticated;
grant select on public.v2_public_partner_form_places to anon,authenticated;

create or replace function public.v2_public_submit_partner_application(p_application jsonb)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 v_id uuid;
 v_type text:=lower(trim(coalesce(p_application->>'application_type','')));
 v_country_id uuid;
 v_other_country text:=nullif(trim(coalesce(p_application->>'other_country_text','')),'');
 v_org_name text:=nullif(trim(coalesce(p_application->>'org_name','')),'');
 v_transport_type_id uuid;
 v_destination_type_id bigint;
 v_fleet_size integer;
 v_place_count integer;
begin
 if v_type not in ('operator','destination') then
  raise exception using errcode='22023',message='application type must be operator or destination';
 end if;
 if v_org_name is null then
  raise exception using errcode='22023',message='organisation name is required';
 end if;
 if char_length(v_org_name)>200 then
  raise exception using errcode='22023',message='organisation name is too long';
 end if;

 begin v_country_id:=nullif(p_application->>'country_id','')::uuid;
 exception when invalid_text_representation then
  raise exception using errcode='22023',message='country is invalid';
 end;
 if v_country_id is not null then
  if not exists(select 1 from pace_v2.countries where id=v_country_id and active) then
   raise exception using errcode='22023',message='country is invalid';
  end if;
  v_other_country:=null;
 elsif v_other_country is null then
  raise exception using errcode='22023',message='country is required';
 elsif char_length(v_other_country)>120 then
  raise exception using errcode='22023',message='country is too long';
 end if;

 if v_type='operator' then
  begin v_transport_type_id:=nullif(p_application->>'transport_type_id','')::uuid;
  exception when invalid_text_representation then
   raise exception using errcode='22023',message='transport type is invalid';
  end;
  if v_transport_type_id is null or not exists(
   select 1 from pace_v2.vehicle_types where id=v_transport_type_id and active
  ) then raise exception using errcode='22023',message='transport type is required'; end if;
  if p_application ? 'fleet_size' and nullif(p_application->>'fleet_size','') is not null then
   begin v_fleet_size:=(p_application->>'fleet_size')::integer;
   exception when invalid_text_representation then
    raise exception using errcode='22023',message='fleet size must be a whole number';
   end;
   if v_fleet_size<0 then raise exception using errcode='22023',message='fleet size cannot be negative'; end if;
  end if;
 else
  begin v_destination_type_id:=nullif(p_application->>'destination_type_id','')::bigint;
  exception when invalid_text_representation then
   raise exception using errcode='22023',message='destination type is invalid';
  end;
  if v_destination_type_id is null or not exists(
   select 1 from pace_v2.destination_types where id=v_destination_type_id and active
  ) then raise exception using errcode='22023',message='destination type is required'; end if;
 end if;

 insert into pace_v2.partner_applications(
  application_type,country_id,other_country_text,org_name,org_address,telephone,mobile,email,website,
  social_instagram,social_youtube,social_x,social_facebook,contact_name,contact_role,years_operation,
  transport_type_id,fleet_size,destination_type_id,pickup_suggestions,destination_suggestions,description,submitted_by
 ) values (
  v_type,v_country_id,v_other_country,v_org_name,
  nullif(trim(coalesce(p_application->>'org_address','')),''),nullif(trim(coalesce(p_application->>'telephone','')),''),
  nullif(trim(coalesce(p_application->>'mobile','')),''),nullif(trim(coalesce(p_application->>'email','')),''),
  nullif(trim(coalesce(p_application->>'website','')),''),nullif(trim(coalesce(p_application->>'social_instagram','')),''),
  nullif(trim(coalesce(p_application->>'social_youtube','')),''),nullif(trim(coalesce(p_application->>'social_x','')),''),
  nullif(trim(coalesce(p_application->>'social_facebook','')),''),nullif(trim(coalesce(p_application->>'contact_name','')),''),
  nullif(trim(coalesce(p_application->>'contact_role','')),''),
  case when nullif(p_application->>'years_operation','') is null then null else (p_application->>'years_operation')::integer end,
  v_transport_type_id,v_fleet_size,v_destination_type_id,
  nullif(trim(coalesce(p_application->>'pickup_suggestions','')),''),
  nullif(trim(coalesce(p_application->>'destination_suggestions','')),''),
  nullif(trim(coalesce(p_application->>'description','')),''),auth.uid()
 ) returning id into v_id;

 if v_type='operator' and jsonb_typeof(p_application->'place_ids')='array' then
  select count(*) into v_place_count from jsonb_array_elements_text(p_application->'place_ids');
  if v_place_count>50 then raise exception using errcode='22023',message='too many supported places'; end if;
  if exists(
   select 1 from jsonb_array_elements_text(p_application->'place_ids') j(value)
   left join pace_v2.transport_type_places p on p.id=j.value::uuid
   where p.id is null or not p.active or p.transport_type_id<>v_transport_type_id
  ) then raise exception using errcode='22023',message='a supported place is invalid for the transport type'; end if;
  insert into pace_v2.partner_application_places(application_id,place_id)
  select v_id,j.value::uuid from jsonb_array_elements_text(p_application->'place_ids') j(value)
  on conflict do nothing;
 end if;

 return v_id;
exception
 when check_violation then
  raise exception using errcode='22023',message='application contains an invalid or overlong value';
end
$$;

revoke all on function public.v2_public_submit_partner_application(jsonb) from public;
grant execute on function public.v2_public_submit_partner_application(jsonb) to anon,authenticated;
