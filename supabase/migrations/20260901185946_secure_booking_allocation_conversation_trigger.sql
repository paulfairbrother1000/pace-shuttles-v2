-- The deferred conversation-identity trigger fires after the protected
-- Stripe finalisation RPC has returned. Run this private trigger as its
-- owner so service_role never needs access to the private pace_v2 schema.
alter function pace_v2.validate_booking_allocation_conversation_change()
  security definer;

alter function pace_v2.validate_booking_allocation_conversation_change()
  set search_path = '';

revoke all on function pace_v2.validate_booking_allocation_conversation_change()
  from public, anon, authenticated, service_role;
