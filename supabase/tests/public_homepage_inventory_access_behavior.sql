begin;

-- The homepage catalogue is a public customer boundary. Both API roles must
-- be able to execute every public inventory view, even when those views use
-- protected eligibility helpers internally.
do $$
begin
  if to_regprocedure('public.v2_public_departure_inventory()') is not null then
    raise exception 'homepage inventory wrapper is exposed as a public RPC';
  end if;
  if to_regprocedure('pace_v2.public_departure_inventory()') is null then
    raise exception 'private homepage inventory wrapper is missing';
  end if;
  if has_function_privilege(
    'anon',
    'pace_v2.get_eligible_vehicle_offers(uuid)',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'pace_v2.get_eligible_vehicle_offers(uuid)',
    'execute'
  ) then
    raise exception 'protected vehicle eligibility helper is executable by an API role';
  end if;
end
$$;

-- PostgREST enforces a short request timeout. A correct permission chain is
-- still unusable if the catalogue scans the full generated timetable.
set local statement_timeout = '2s';

set local role anon;
select count(*) from public.v2_public_departures;
select count(*) from public.v2_public_countries;
select count(*) from public.v2_public_pickups;
select count(*) from public.v2_public_destinations;

reset role;
set local role authenticated;
select count(*) from public.v2_public_departures;
select count(*) from public.v2_public_countries;
select count(*) from public.v2_public_pickups;
select count(*) from public.v2_public_destinations;

reset role;
rollback;
