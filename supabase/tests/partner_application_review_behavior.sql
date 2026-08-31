begin;

do $$
declare
 v_country uuid;
 v_transport uuid;
 v_destination_type bigint;
 v_operator_application uuid;
 v_destination_application uuid;
 v_rejected_application uuid;
begin
 select id into v_country from pace_v2.countries where active order by name limit 1;
 select id into v_transport from pace_v2.vehicle_types where active order by name limit 1;
 select id into v_destination_type from pace_v2.destination_types where active order by display_order,type limit 1;

 v_operator_application:=public.v2_public_submit_partner_application(jsonb_build_object(
  'application_type','operator','country_id',v_country,'org_name','Promotion Test Operator',
  'email','promotion-operator@example.test','telephone','+1 268 555 0101','transport_type_id',v_transport
 ));
 v_destination_application:=public.v2_public_submit_partner_application(jsonb_build_object(
  'application_type','destination','country_id',v_country,'org_name','Promotion Test Destination',
  'email','promotion-destination@example.test','destination_type_id',v_destination_type,'description','Draft description'
 ));
 v_rejected_application:=public.v2_public_submit_partner_application(jsonb_build_object(
  'application_type','destination','country_id',v_country,'org_name','Rejected Test Destination',
  'destination_type_id',v_destination_type
  ));

 perform set_config('test.operator_application',v_operator_application::text,true);
 perform set_config('test.destination_application',v_destination_application::text,true);
 perform set_config('test.rejected_application',v_rejected_application::text,true);
end
$$;

select set_config('request.jwt.claim.sub',(
 select user_id::text from pace_v2.profiles where platform_role='site_admin' order by user_id limit 1
),true);
set local role authenticated;

select public.v2_admin_set_partner_application_status(
 current_setting('test.rejected_application')::uuid,'rejected','Does not meet requirements'
);
select public.v2_admin_set_partner_application_status(
 current_setting('test.rejected_application')::uuid,'under_review','Reconsidering'
);
select public.v2_admin_set_partner_application_status(
 current_setting('test.rejected_application')::uuid,'rejected','Final rejection'
);

select public.v2_admin_approve_partner_application(current_setting('test.operator_application')::uuid);
select public.v2_admin_approve_partner_application(current_setting('test.operator_application')::uuid);
select public.v2_admin_approve_partner_application(current_setting('test.destination_application')::uuid);
select public.v2_admin_approve_partner_application(current_setting('test.destination_application')::uuid);

reset role;

do $$
declare
 v_operator_application uuid:=current_setting('test.operator_application')::uuid;
 v_destination_application uuid:=current_setting('test.destination_application')::uuid;
 v_rejected_application uuid:=current_setting('test.rejected_application')::uuid;
 v_operator uuid;
 v_destination uuid;
begin
 select operator_id into v_operator from pace_v2.partner_applications where id=v_operator_application;
 if v_operator is null then raise exception 'operator approval did not link an operator'; end if;
 if not exists(select 1 from pace_v2.operators where id=v_operator and name='Promotion Test Operator' and not active)
 then raise exception 'approved operator must be present and inactive'; end if;
 if (select count(*) from pace_v2.operators where id=v_operator)<>1
 then raise exception 'operator approval was not idempotent'; end if;
 if not exists(select 1 from pace_v2.operator_vehicle_types ovt join pace_v2.partner_applications a on a.id=v_operator_application
   where ovt.operator_id=v_operator and ovt.vehicle_type_id=a.transport_type_id and ovt.status='approved')
 then raise exception 'approved operator transport type was not created'; end if;

 select destination_id into v_destination from pace_v2.partner_applications where id=v_destination_application;
 if v_destination is null then raise exception 'destination approval did not link a destination'; end if;
 if not exists(select 1 from pace_v2.destinations where id=v_destination and name='Promotion Test Destination' and not active)
 then raise exception 'approved destination must be an inactive draft'; end if;
 if (select count(*) from pace_v2.destinations where id=v_destination)<>1
 then raise exception 'destination approval was not idempotent'; end if;

 if exists(select 1 from pace_v2.partner_applications where id=v_rejected_application
   and (status<>'rejected' or operator_id is not null or destination_id is not null))
 then raise exception 'rejection must not promote an application'; end if;
end
$$;

rollback;
