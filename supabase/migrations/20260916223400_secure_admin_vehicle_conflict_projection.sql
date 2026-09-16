-- Keep the internal resource-window helper private while allowing the
-- authenticated Site Admin view to identify the overlapping journey.
create or replace function pace_v2.site_admin_conflicting_departure_id(
  p_departure_id uuid,
  p_vehicle_id uuid
)
returns uuid
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  conflicting_departure_id uuid;
begin
  if not pace_v2.is_site_admin() then
    return null;
  end if;

  select other_allocation.departure_id
  into conflicting_departure_id
  from pace_v2.captain_duty_resource_window(p_departure_id) current_resource
  join pace_v2.confirmed_allocations other_allocation
    on other_allocation.vehicle_id=p_vehicle_id
   and other_allocation.status='confirmed'
   and other_allocation.departure_id<>current_resource.outbound_departure_id
  cross join lateral pace_v2.captain_duty_resource_window(
    other_allocation.departure_id
  ) other_resource
  where other_resource.scheduled_start_ts<current_resource.scheduled_end_ts
    and other_resource.scheduled_end_ts>current_resource.scheduled_start_ts
  order by other_resource.scheduled_start_ts,other_allocation.departure_id
  limit 1;

  return conflicting_departure_id;
end;
$$;

revoke all on function pace_v2.site_admin_conflicting_departure_id(uuid,uuid)
  from public,anon,authenticated,service_role;
grant execute on function pace_v2.site_admin_conflicting_departure_id(uuid,uuid)
  to authenticated;

create or replace view public.v2_admin_vehicle_considerations as
select
  vc.id as consideration_id,vc.departure_id,vc.vehicle_route_offer_id,
  vc.vehicle_id,v.name as vehicle_name,vc.operator_id,o.name as operator_name,
  vc.status,vc.normal_min_seats,vc.max_seats,vc.min_revenue_cents,
  vc.min_value_threshold_ratio,vc.normal_base_seat_price_cents,
  vc.assigned_seats,vc.assigned_revenue_cents,vc.minimum_achieved_at,
  vc.discount_activated_at,vc.opened_at,vc.under_consideration_at,
  vc.withdrawal_deadline_ts,vc.withdrawn_at,vc.withdrawal_reason,
  vc.t72_discarded_at,vc.quality_score_snapshot,vc.effective_commission_bps,
  vc.effective_commission_source,vc.engine_version,vc.updated_at,
  vc.post_min_discount_enabled,vc.post_min_discount_bps,
  vc.commercial_snapshot_locked_at,vc.commercial_snapshot_source,
  pace_v2.site_admin_conflicting_departure_id(vc.departure_id,vc.vehicle_id)
    as conflicting_departure_id
from pace_v2.vehicle_considerations vc
join pace_v2.vehicles v on v.id=vc.vehicle_id
join pace_v2.operators o on o.id=vc.operator_id
where pace_v2.is_site_admin();
