begin;
\ir fixtures/completion_feedback.sql
do $test$
declare sid uuid;
begin
  if exists(select 1 from pace_v2.settlements) then raise exception 'settlement exists before recorded completion'; end if;
  perform pg_temp.complete_fixture();
  if (select count(*) from pace_v2.settlements where status='pending' and journey_value_cents=2000 and commission_cents=200 and net_payable_cents=1800)<>2 then raise exception 'genuine completion must accrue two pending settlements'; end if;
  if (select count(*) from pace_v2.ledger_transactions where transaction_type='journey_settlement_accrual')<>2 then raise exception 'accrual transaction count incorrect'; end if;
  if exists(select 1 from pace_v2.ledger_transactions t join pace_v2.ledger_entries e on e.ledger_transaction_id=t.id where t.transaction_type='journey_settlement_accrual' group by t.id having sum(case e.side when 'debit' then e.amount_cents else -e.amount_cents end)<>0) then raise exception 'accrual is not balanced'; end if;
  perform set_config('request.jwt.claim.sub',pg_temp.fid(103)::text,true);
  perform public.v2_captain_end_leg(pg_temp.fid(31),'normal',null,null,pg_temp.fid(51));
  perform set_config('request.jwt.claim.sub',pg_temp.fid(100)::text,true);
  sid:=public.v2_admin_create_settlement(pg_temp.fid(50),now());
  if (select count(*) from pace_v2.settlements)<>2 or (select count(*) from pace_v2.ledger_transactions where transaction_type='journey_settlement_accrual')<>2 then raise exception 'completion or admin retry duplicated accrual'; end if;
end $test$;
rollback;
