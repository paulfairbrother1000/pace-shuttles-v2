begin;
\ir fixtures/completion_feedback.sql
do $test$
declare completed timestamptz; due timestamptz;
begin
  if pace_v2.feedback_due_at('2026-10-09 17:00:00Z','America/Antigua') is distinct from '2026-10-09 21:00:00Z'::timestamptz then raise exception 'feedback must be due four elapsed hours after completion'; end if;
  if pace_v2.feedback_due_at('2030-03-10 04:30:00Z','America/New_York') is distinct from '2030-03-10 08:30:00Z'::timestamptz then raise exception 'spring DST changed elapsed delay'; end if;
  if pace_v2.feedback_due_at('2030-11-03 03:30:00Z','America/New_York') is distinct from '2030-11-03 07:30:00Z'::timestamptz then raise exception 'fall DST changed elapsed delay'; end if;
  begin
    perform pace_v2.feedback_due_at(now(),'Not/A-Timezone');
    raise exception 'invalid timezone accepted';
  exception when invalid_parameter_value then null; end;
  if public.v2_system_schedule_feedback_requests(now()+interval '1 month',100)<>0 then raise exception 'feedback queued without recorded completion'; end if;
  perform pg_temp.complete_fixture();
  select completed_at into completed from pace_v2.departures where id=pg_temp.fid(30);
  due:=completed+interval '4 hours';
  if public.v2_system_schedule_feedback_requests(due-interval '1 second',100)<>0 then raise exception 'feedback queued before four-hour boundary'; end if;
  if public.v2_system_schedule_feedback_requests(due,100)<>2 then raise exception 'two paid parties were not queued at four-hour boundary'; end if;
  if public.v2_system_schedule_feedback_requests(due+interval '1 day',100)<>0 then raise exception 'late catch-up duplicated invitations'; end if;
  if exists(select 1 from pace_v2.notifications where template_code='post_journey_feedback' and scheduled_at is distinct from due) then raise exception 'invitation due time differs from actual final completion plus four hours'; end if;
end $test$;
rollback;
