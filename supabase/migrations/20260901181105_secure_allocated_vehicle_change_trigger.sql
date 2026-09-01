-- This deferred constraint trigger fires after the protected vehicle-save RPC
-- has returned. Run only the trigger as its private-schema owner so the
-- authenticated caller does not need direct access to confirmed allocations.
alter function pace_v2.validate_allocated_vehicle_change()
  security definer;

alter function pace_v2.validate_allocated_vehicle_change()
  set search_path = '';

revoke all on function pace_v2.validate_allocated_vehicle_change()
  from public, anon, authenticated;
