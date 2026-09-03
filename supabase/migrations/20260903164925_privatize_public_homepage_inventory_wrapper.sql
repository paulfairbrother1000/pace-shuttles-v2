-- The wrapper is intentionally callable through the public inventory view,
-- but it must not also become an exposed /rest/v1/rpc endpoint.
alter function public.v2_public_departure_inventory() set schema pace_v2;
alter function pace_v2.v2_public_departure_inventory()
rename to public_departure_inventory;

revoke all on function pace_v2.public_departure_inventory()
from public, anon, authenticated;
grant execute on function pace_v2.public_departure_inventory()
to anon, authenticated;

create or replace view public.v2_public_departures as
select * from pace_v2.public_departure_inventory();

grant select on public.v2_public_departures to anon, authenticated;

notify pgrst, 'reload schema';
