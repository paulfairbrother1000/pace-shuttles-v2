begin;
\ir fixtures/completion_feedback.sql
select set_config('pace_v2.journey_pair_mutation_authorized','on',true);
update pace_v2.departures set scheduled_departure_ts=scheduled_departure_ts-interval '3 days',scheduled_arrival_ts=scheduled_arrival_ts-interval '3 days',t72_ts=t72_ts-interval '3 days',t24_ts=t24_ts-interval '3 days' where id in(pg_temp.fid(30),pg_temp.fid(31));
select set_config('pace_v2.journey_pair_mutation_authorized','off',true);
update pace_v2.bookings set status='completed' where departure_id=pg_temp.fid(30);
update pace_v2.departures set status='completed' where id=pg_temp.fid(30);
do $test$
begin
  perform public.v2_system_reconcile_empty_paired_returns(1000);
  if (select status from pace_v2.departures where id=pg_temp.fid(31))='cancelled' then raise exception 'completed outbound parties were mistaken for an empty return'; end if;
  perform public.v2_system_run_scheduled_operations();
  if (select status from pace_v2.departures where id=pg_temp.fid(31))<>'closed_unrecorded' then raise exception 'unrecorded return must close as unrecorded, not invent travel'; end if;
  update pace_v2.departures set status='scheduled' where id=pg_temp.fid(31);
  update pace_v2.bookings set status='cancelled' where departure_id=pg_temp.fid(30);
  perform public.v2_system_reconcile_empty_paired_returns(1000);
  if (select status from pace_v2.departures where id=pg_temp.fid(31))<>'cancelled' then raise exception 'cancelled-only parties must not keep an empty return open'; end if;
end $test$;
rollback;
