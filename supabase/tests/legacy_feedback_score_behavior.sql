-- Disposable database only: committed synthetic fixture enables HTTP-like timing.
begin;
\ir fixtures/completion_feedback.sql
select pg_temp.complete_fixture();
commit;
begin;
do $test$
declare feedback uuid;
begin
  perform set_config('request.jwt.claim.sub',pg_temp.fid(101)::text,true);
  feedback:=public.v2_customer_submit_feedback(pg_temp.fid(80),10,5,'Legacy feedback','operator');
  if (select feedback_schema_version from pace_v2.customer_feedback where id=feedback)<>1 then raise exception 'legacy RPC must mark its schema explicitly'; end if;
  if (select quality_score from pace_v2.operators where id=pg_temp.fid(7))<>51.00 then raise exception 'legacy operator rating failed or platform NPS inflated operator score'; end if;
  perform set_config('request.jwt.claim.sub',pg_temp.fid(100)::text,true);
  perform public.v2_admin_review_feedback(feedback,'external');
  if (select quality_score from pace_v2.operators where id=pg_temp.fid(7))<>50.00 then raise exception 'legacy external attribution review failed'; end if;
end $test$;
rollback;
