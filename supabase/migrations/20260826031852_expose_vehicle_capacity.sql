create or replace view public.v2_vehicles as
select
  id,
  operator_id,
  vehicle_type_id,
  name,
  description,
  picture_url,
  active,
  default_min_seats,
  default_max_seats,
  default_min_revenue_cents,
  default_min_value_threshold_ratio,
  default_max_seat_discount_bps,
  created_at,
  updated_at,
  capacity_seats
from pace_v2.vehicles
where pace_v2.is_site_admin();

create or replace view public.v2_operator_my_fleet as
select
  v.id as vehicle_id,
  v.operator_id,
  v.vehicle_type_id,
  vt.name as vehicle_type_name,
  v.name,
  v.description,
  v.active,
  v.default_min_seats,
  v.default_max_seats,
  v.default_min_revenue_cents,
  v.default_min_value_threshold_ratio,
  v.default_max_seat_discount_bps,
  v.capacity_seats
from pace_v2.vehicles v
join pace_v2.vehicle_types vt on vt.id = v.vehicle_type_id
where exists (
  select 1
  from pace_v2.operator_memberships om
  where om.operator_id = v.operator_id
    and om.user_id = auth.uid()
    and om.active
);

