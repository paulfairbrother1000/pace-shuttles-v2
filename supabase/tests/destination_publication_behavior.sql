begin;

do $$
declare v_country uuid;v_destination uuid;
begin
 select id into v_country from pace_v2.countries where active and not is_large order by name limit 1;
 insert into pace_v2.destinations(country_id,name,active) values(v_country,'Publication Contract Destination',false) returning id into v_destination;
 perform set_config('test.publication_destination',v_destination::text,true);
end
$$;

select set_config('request.jwt.claim.sub',(
 select user_id::text from pace_v2.profiles where platform_role='site_admin' order by user_id limit 1
),true);
set local role authenticated;

do $$
declare v_id uuid:=current_setting('test.publication_destination')::uuid;v_rejected boolean:=false;
begin
 begin perform public.v2_admin_set_destination_published(v_id,true);
 exception when invalid_parameter_value then v_rejected:=true; end;
 if not v_rejected then raise exception 'incomplete destination was published'; end if;
end
$$;

reset role;

update pace_v2.destinations set
 destination_type='Beach Club',description='A complete destination',picture_url='https://images.example.test/destination.jpg',
 address1='Test Harbour',latitude=17.1,longitude=-61.8,directions_url='https://maps.app.goo.gl/test',
 wet_or_dry='wet',arrival_notes='Use the guest dock',email='destination@example.test'
where id=current_setting('test.publication_destination')::uuid;

set local role authenticated;
select public.v2_admin_set_destination_published(current_setting('test.publication_destination')::uuid,true);
reset role;

do $$
declare v_id uuid:=current_setting('test.publication_destination')::uuid;
begin
 if not exists(select 1 from pace_v2.destinations where id=v_id and active and published_at is not null and published_by is not null)
 then raise exception 'complete destination was not published with audit fields'; end if;
 if not exists(select 1 from public.v2_public_destinations where id=v_id)
 then raise exception 'published destination is missing from the public catalogue'; end if;
end
$$;

set local role authenticated;
select public.v2_admin_set_destination_published(current_setting('test.publication_destination')::uuid,false);
reset role;

do $$
declare v_id uuid:=current_setting('test.publication_destination')::uuid;
begin
 if exists(select 1 from public.v2_public_destinations where id=v_id)
 then raise exception 'unpublished destination remains public'; end if;
 if not exists(select 1 from pace_v2.destinations where id=v_id and not active)
 then raise exception 'unpublish must retain the inactive destination record'; end if;
 if exists(select 1 from pace_v2.destinations where active and published_at is null)
 then raise exception 'existing active destinations were not backfilled as published'; end if;
end
$$;

rollback;
