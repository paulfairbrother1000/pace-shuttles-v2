select pace_v2.backfill_default_return_journeys(250);

with canonical_windows as (
  select
    reservation.id,
    resource.scheduled_start_ts,
    resource.scheduled_end_ts
  from pace_v2.captain_duty_reservations reservation
  cross join lateral pace_v2.captain_duty_resource_window(
    reservation.departure_id
  ) resource
  where reservation.state in('provisional','held_t72','confirmed_t24')
)
update pace_v2.captain_duty_reservations reservation
set duty_start_ts=canonical.scheduled_start_ts,
    duty_end_ts=canonical.scheduled_end_ts
from canonical_windows canonical
where reservation.id=canonical.id
  and (
    reservation.duty_start_ts is distinct from canonical.scheduled_start_ts
    or reservation.duty_end_ts is distinct from canonical.scheduled_end_ts
  );

do $$
begin
  if exists(
    select 1
    from pace_v2.departures departure
    join pace_v2.services service
      on service.id=departure.service_id
     and service.active
    where departure.is_commercial
      and departure.scheduled_departure_ts>now()
      and departure.status not in('cancelled','completed')
      and departure.journey_pair_id is null
  ) then
    raise exception 'future active return inventory exceeds the bounded backfill capacity';
  end if;
end
$$;
