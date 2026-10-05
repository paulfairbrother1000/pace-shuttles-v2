begin;
\ir fixtures/completion_feedback.sql
do $test$
declare ended timestamptz; before_retry timestamptz;
begin
  perform set_config('request.jwt.claim.sub',pg_temp.fid(104)::text,true);
  begin
    perform public.v2_captain_start_leg(pg_temp.fid(30),pg_temp.fid(50));
    raise exception 'unassigned user started a captain duty';
  exception when others then
    if sqlerrm<>'captain assignment required' then raise; end if;
  end;
  perform set_config('request.jwt.claim.sub',pg_temp.fid(102)::text,true);
  if not exists(select 1 from pace_v2.captain_today_manifest() where booking_id=pg_temp.fid(80) and leg_1_departure_id=pg_temp.fid(30) and leg_2_departure_id=pg_temp.fid(31)) then raise exception 'whole-party manifest must serve both legs'; end if;
  perform public.v2_captain_start_leg(pg_temp.fid(30),pg_temp.fid(50));
  perform public.v2_captain_end_leg(pg_temp.fid(30),'normal',null,null,pg_temp.fid(50));
  perform public.v2_captain_start_leg(pg_temp.fid(31),pg_temp.fid(50));
  ended:=public.v2_captain_end_leg(pg_temp.fid(31),'normal',null,null,pg_temp.fid(50));
  if exists(select 1 from pace_v2.departures where id=pg_temp.fid(30) and status='completed') then raise exception 'pair completed before second boat ended'; end if;
  before_retry:=public.v2_captain_end_leg(pg_temp.fid(31),'normal',null,null,pg_temp.fid(50));
  if before_retry is distinct from ended then raise exception 'retry changed actual end evidence'; end if;
  perform set_config('request.jwt.claim.sub',pg_temp.fid(103)::text,true);
  perform public.v2_captain_start_leg(pg_temp.fid(30),pg_temp.fid(51));
  perform public.v2_captain_end_leg(pg_temp.fid(30),'normal',null,null,pg_temp.fid(51));
  perform public.v2_captain_start_leg(pg_temp.fid(31),pg_temp.fid(51));
  perform public.v2_captain_end_leg(pg_temp.fid(31),'normal',null,null,pg_temp.fid(51));
  if (select count(*) from pace_v2.departures where id in(pg_temp.fid(30),pg_temp.fid(31)) and status='completed')<>2 then raise exception 'both genuinely completed legs must be completed'; end if;
  if exists(select 1 from pace_v2.departures d where id in(pg_temp.fid(30),pg_temp.fid(31)) and (d.actual_departure_ts is distinct from (select min(started_at) from pace_v2.captain_leg_operations o where o.departure_id=d.id) or d.actual_arrival_ts is distinct from (select max(ended_at) from pace_v2.captain_leg_operations o where o.departure_id=d.id))) then raise exception 'departure timestamps must reflect their own leg evidence'; end if;
  if (select count(*) from pace_v2.bookings where departure_id=pg_temp.fid(30))<>2 or exists(select 1 from pace_v2.bookings where departure_id=pg_temp.fid(31)) then raise exception 'return must inherit parties, not duplicate bookings'; end if;
end $test$;
rollback;
