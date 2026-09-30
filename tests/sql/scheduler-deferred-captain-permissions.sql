-- Run against a database with a valid future confirmed allocation fixture.
-- Rollback alone skips deferred constraints and cannot prove this path works.
BEGIN;
DO $$
DECLARE allocation_id uuid;
BEGIN
  SELECT a.id INTO allocation_id
  FROM pace_v2.confirmed_allocations a
  JOIN pace_v2.departures d ON d.id=a.departure_id
  WHERE a.status='confirmed' AND d.scheduled_departure_ts>now()
  ORDER BY a.confirmed_at DESC LIMIT 1;
  IF allocation_id IS NULL THEN
    RAISE EXCEPTION 'Test requires a valid future confirmed allocation fixture';
  END IF;
  -- Models the write inside a privileged RPC before returning to the API role.
  UPDATE pace_v2.confirmed_allocations SET status=status WHERE id=allocation_id;
END $$;
SET LOCAL ROLE service_role;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
