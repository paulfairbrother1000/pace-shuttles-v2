-- Return legs generated as non-commercial departures need their own empty
-- reconciliation branch: the existing scheduler only closes a paired return
-- if the outbound has a qualifying booking.
create or replace function public.v2_system_reconcile_empty_paired_returns(
  p_limit integer default 100
)
returns integer
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_count integer;
begin
  with targets as (
    select d.id
    from pace_v2.departures d
    where d.is_commercial=false
      and d.leg_number=2
      and d.journey_pair_id is not null
      and d.status not in('completed','cancelled','closed_unrecorded')
      and d.actual_arrival_ts is null
      and coalesce(d.scheduled_arrival_ts,d.scheduled_departure_ts+interval '8 hours')
          +interval '24 hours' <= now()
      and not exists (
        select 1
        from pace_v2.departures paired
        join pace_v2.bookings b on b.departure_id=paired.id
        where paired.journey_pair_id=d.journey_pair_id
          and b.status in('booked','at_risk','confirmed')
      )
    order by d.scheduled_departure_ts,d.id
    limit greatest(1,least(coalesce(p_limit,100),1000))
    for update skip locked
  )
  update pace_v2.departures d
  set status='cancelled',
      cancelled_reason='Closed after departure — no paired bookings.',
      at_risk_reason=null
  from targets t where d.id=t.id;
  get diagnostics v_count=row_count;
  return v_count;
end
$function$;

revoke all on function public.v2_system_reconcile_empty_paired_returns(integer)
  from public,anon,authenticated;
grant execute on function public.v2_system_reconcile_empty_paired_returns(integer)
  to service_role;
