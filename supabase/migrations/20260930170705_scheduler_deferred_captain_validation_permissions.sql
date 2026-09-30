-- Deferred SECURITY INVOKER constraints execute as the original API role
-- after the SECURITY DEFINER allocation RPC returns. The helper remains
-- private to postgres and the server role; no public/client grants are added.
GRANT USAGE ON SCHEMA pace_v2 TO service_role;
GRANT EXECUTE ON FUNCTION pace_v2.assert_confirmed_allocation_has_eligible_captain(uuid) TO service_role;
