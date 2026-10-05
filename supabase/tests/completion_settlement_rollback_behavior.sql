begin;
\ir fixtures/completion_feedback.sql
do $test$
begin
  perform set_config('request.jwt.claim.sub',pg_temp.fid(104)::text,true);
  begin
    perform pace_v2.captain_complete_journey(pg_temp.fid(60));
    raise exception 'foreign user completed captain assignment';
  exception when raise_exception then
    if sqlerrm<>'Active captain assignment required' then raise; end if;
  end;
  update pace_v2.ledger_accounts set active=false where account_code='PS-COMMISSION';
  begin
    perform pg_temp.complete_fixture();
    raise exception 'completion accepted missing commission account';
  exception when raise_exception then
    if sqlerrm not like 'Settlement accrual requires active USD%' then raise; end if;
  end;
  if exists(select 1 from pace_v2.settlements) or exists(select 1 from pace_v2.departures where status='completed') then raise exception 'failed accrual left partial completion or settlement'; end if;
  update pace_v2.ledger_accounts set active=true where account_code='PS-COMMISSION';
  perform pg_temp.complete_fixture();
  if (select count(*) from pace_v2.settlements where status='pending')<>2 then raise exception 'retry after account repair did not accrue once per boat'; end if;
end $test$;
rollback;
