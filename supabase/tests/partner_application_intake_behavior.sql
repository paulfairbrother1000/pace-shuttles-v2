begin;

create temporary table partner_intake_results(kind text primary key,id uuid not null);
grant select,insert on partner_intake_results to anon;

set local role anon;

insert into partner_intake_results values ('operator',public.v2_public_submit_partner_application(
 jsonb_build_object(
  'application_type','operator',
  'country_id',(select id from public.v2_public_partner_form_countries order by name limit 1),
  'org_name','  Contract Test Operator  ',
  'email','operator@example.test',
  'transport_type_id',(select id from public.v2_public_partner_form_transport_types order by name limit 1),
  'fleet_size',3,
  'status','approved',
  'admin_notes','must not be accepted',
  'operator_id',gen_random_uuid()
 )
));

insert into partner_intake_results values ('destination',public.v2_public_submit_partner_application(
 jsonb_build_object(
  'application_type','destination',
  'country_id',(select id from public.v2_public_partner_form_countries order by name limit 1),
  'org_name','Contract Test Destination',
  'destination_type_id',(select id from public.v2_public_partner_form_destination_types order by display_order,type limit 1),
  'description','A prospective destination'
 )
));

reset role;

do $$
declare v_operator uuid;v_destination uuid;v_rejected boolean;
begin
 select id into v_operator from partner_intake_results where kind='operator';
 select id into v_destination from partner_intake_results where kind='destination';

 if not exists(select 1 from pace_v2.partner_applications where id=v_operator and application_type='operator'
   and status='new' and org_name='Contract Test Operator' and admin_notes is null and operator_id is null and destination_id is null)
 then raise exception 'operator submission was not cleaned or privileged fields were accepted'; end if;

 if not exists(select 1 from pace_v2.partner_applications where id=v_destination and application_type='destination'
   and status='new' and destination_type_id is not null and operator_id is null and destination_id is null)
 then raise exception 'destination submission was not stored as new'; end if;

 v_rejected:=false;
 begin
  perform public.v2_public_submit_partner_application(jsonb_build_object(
   'application_type','operator','org_name','Invalid fleet','other_country_text','Nowhere',
   'transport_type_id',(select id from pace_v2.vehicle_types where active order by name limit 1),'fleet_size',-1));
 exception when check_violation or invalid_parameter_value then v_rejected:=true;
 end;
 if not v_rejected then raise exception 'negative fleet size was accepted'; end if;

 v_rejected:=false;
 begin
  perform public.v2_public_submit_partner_application(jsonb_build_object(
   'application_type','destination','org_name','Invalid type','other_country_text','Nowhere','destination_type_id',-999999));
 exception when foreign_key_violation or invalid_parameter_value then v_rejected:=true;
 end;
 if not v_rejected then raise exception 'invalid destination type was accepted'; end if;

 v_rejected:=false;
 begin
  perform public.v2_public_submit_partner_application(jsonb_build_object(
   'application_type','operator','org_name','Missing type','other_country_text','Nowhere'));
 exception when not_null_violation or invalid_parameter_value then v_rejected:=true;
 end;
 if not v_rejected then raise exception 'operator without transport type was accepted'; end if;

 if exists(select 1 from pace_v2.partner_application_places p
   left join pace_v2.partner_applications a on a.id=p.application_id where a.id is null)
 then raise exception 'partial or orphan application-place rows exist'; end if;
end
$$;

rollback;
