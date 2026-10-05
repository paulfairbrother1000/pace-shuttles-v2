begin;
\ir fixtures/completion_feedback.sql
-- Synthetic immutable evidence for a boat that finished before its peer.
insert into pace_v2.captain_leg_operations(departure_id,confirmed_allocation_id,captain_assignment_id,started_at,started_by_user_id,ended_at,ended_by_user_id,completion_state)
values
 (pg_temp.fid(30),pg_temp.fid(50),pg_temp.fid(60),now()-interval '50 minutes',pg_temp.fid(102),now()-interval '45 minutes',pg_temp.fid(102),'normal'),
 (pg_temp.fid(31),pg_temp.fid(50),pg_temp.fid(60),now()-interval '40 minutes',pg_temp.fid(102),now()-interval '20 minutes',pg_temp.fid(102),'normal');
do $test$
begin
  perform set_config('request.jwt.claim.sub',pg_temp.fid(103)::text,true);
  perform public.v2_captain_start_leg(pg_temp.fid(30),pg_temp.fid(51));
  perform public.v2_captain_end_leg(pg_temp.fid(30),'normal',null,null,pg_temp.fid(51));
  perform public.v2_captain_start_leg(pg_temp.fid(31),pg_temp.fid(51));
  perform public.v2_captain_end_leg(pg_temp.fid(31),'normal',null,null,pg_temp.fid(51));
  if exists(select 1 from pace_v2.settlements s join pace_v2.captain_leg_operations o on o.confirmed_allocation_id=s.confirmed_allocation_id and o.departure_id=pg_temp.fid(31) where s.due_at is distinct from o.ended_at) then raise exception 'settlement due time must use each boat recorded final end'; end if;
  if exists(select 1 from pace_v2.quality_evidence qe join pace_v2.voyage_logs vl on vl.id=qe.source_id where qe.evidence_type='journey_completed' and (qe.occurred_at is distinct from vl.actual_arrival_ts or (qe.evidence_payload->>'actual_arrival_ts')::timestamptz is distinct from vl.actual_arrival_ts or (qe.evidence_payload->>'actual_departure_ts')::timestamptz is distinct from vl.actual_departure_ts)) then raise exception 'immutable audit evidence must agree with genuine captain operation times'; end if;
end $test$;
rollback;
