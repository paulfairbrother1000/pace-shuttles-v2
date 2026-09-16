-- A consideration can stop being eligible before T-72 because its vehicle has
-- already been confirmed on an overlapping journey. Expose that journey to
-- Site Admin so the UI does not misdescribe the resource conflict as a T-72
-- allocation decision.
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
  conflict.departure_id as conflicting_departure_id
from pace_v2.vehicle_considerations vc
join pace_v2.vehicles v on v.id=vc.vehicle_id
join pace_v2.operators o on o.id=vc.operator_id
cross join lateral pace_v2.captain_duty_resource_window(vc.departure_id)
  current_resource
left join lateral (
  select other_allocation.departure_id
  from pace_v2.confirmed_allocations other_allocation
  cross join lateral pace_v2.captain_duty_resource_window(
    other_allocation.departure_id
  ) other_resource
  where other_allocation.vehicle_id=vc.vehicle_id
    and other_allocation.status='confirmed'
    and other_allocation.departure_id<>current_resource.outbound_departure_id
    and other_resource.scheduled_start_ts<current_resource.scheduled_end_ts
    and other_resource.scheduled_end_ts>current_resource.scheduled_start_ts
  order by other_resource.scheduled_start_ts,other_allocation.departure_id
  limit 1
) conflict on true
where pace_v2.is_site_admin();
