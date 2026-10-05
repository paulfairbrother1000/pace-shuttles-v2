-- Use separate transactions as real completion and feedback HTTP requests do.
-- This file must run in a disposable database: fixture setup is committed.
begin;
\ir fixtures/completion_feedback.sql
select pg_temp.complete_fixture();
commit;
begin;
do $test$
declare feedback uuid; second_feedback uuid; effect numeric; before_count integer;
begin
  perform set_config('request.jwt.claim.sub',pg_temp.fid(104)::text,true);
  begin
    perform public.v2_customer_submit_feedback(pg_temp.fid(80),5,10,5,3,5,5,null,null,false);
    raise exception 'non-owner submitted feedback';
  exception when others then
    if sqlerrm<>'eligible paid booking owned by the authenticated customer required' then raise; end if;
  end;
  perform set_config('request.jwt.claim.sub',pg_temp.fid(101)::text,true);
  feedback:=public.v2_customer_submit_feedback(pg_temp.fid(80),5,10,5,3,5,5,null,null,false);
  if (select quality_score from pace_v2.operators where id=pg_temp.fid(7))<>50.60 then raise exception 'operator score did not refresh to 50.60 after 60-percent operator contribution'; end if;
  if (select count(*) from pace_v2.quality_evidence where feedback_id=feedback or (source_table='customer_feedback' and source_id=feedback))<>6 then raise exception 'legacy trigger duplicated version-two feedback evidence'; end if;
  select weighted_effect into effect from pace_v2.calculate_operator_quality_score(pg_temp.fid(7),now());
  if abs(effect-0.6)>0.00001 then raise exception 'operator=5 captain=3 should contribute 0.6, got %',effect; end if;
  -- Reproduce historical overlapping evidence without deleting audit history.
  insert into pace_v2.quality_evidence(departure_id,operator_id,evidence_type,attribution,score_effect,source_table,source_id,occurred_at)
  values(pg_temp.fid(30),pg_temp.fid(7),'operator_journey_rating','operator',1,'customer_feedback',feedback,now()),
        (pg_temp.fid(30),pg_temp.fid(7),'customer_nps','operator',1,'customer_feedback',feedback,now());
  select weighted_effect into effect from pace_v2.calculate_operator_quality_score(pg_temp.fid(7),now());
  if abs(effect-0.6)>0.00001 then raise exception 'historical duplicate evidence was counted twice'; end if;
  select count(*) into before_count from pace_v2.quality_evidence;
  begin
    perform public.v2_customer_submit_feedback(pg_temp.fid(80),5,10,5,3,5,5,null,null,false);
    raise exception 'duplicate feedback accepted';
  exception when unique_violation then null; end;
  if (select count(*) from pace_v2.quality_evidence)<>before_count then raise exception 'retry changed score evidence'; end if;
  second_feedback:=public.v2_customer_submit_feedback(pg_temp.fid(81),3,0,3,5,3,3,null,null,false);
  select weighted_effect into effect from pace_v2.calculate_operator_quality_score(pg_temp.fid(7),now());
  if abs(effect-1)>0.00001 then raise exception 'captain=5 should add 0.4; NPS=0 must not reduce operator score, got %',effect; end if;
  if (select quality_score from pace_v2.operators where id=pg_temp.fid(7))<>51.00 then raise exception 'second feedback did not refresh score'; end if;
  perform set_config('request.jwt.claim.sub',pg_temp.fid(100)::text,true);
  perform public.v2_admin_review_feedback(feedback,'external');
  if (select quality_score from pace_v2.operators where id=pg_temp.fid(7))<>50.40 then raise exception 'external attribution review did not remove operator impact'; end if;
end $test$;
rollback;
