-- Disposable database only: committed synthetic fixture.
begin;
\ir fixtures/completion_feedback.sql
insert into pace_v2.orders(id,customer_user_id,customer_email,customer_name,subtotal_cents,total_cents,payment_status,paid_at,fulfillment_status)
values(pg_temp.fid(72),pg_temp.fid(101),'fixture-101@example.invalid','Fixture Customer',2000,2000,'paid',now(),'booked');
insert into pace_v2.bookings(id,order_id,departure_id,route_id,customer_name,seats,status,unit_price_cents,total_price_cents,paid_at)
values(pg_temp.fid(82),pg_temp.fid(72),pg_temp.fid(30),pg_temp.fid(4),'Fixture Customer',2,'confirmed',1000,2000,now());
insert into pace_v2.booking_allocations(booking_id,departure_id,vehicle_consideration_id,vehicle_id,status,seats,unit_price_cents)
values(pg_temp.fid(82),pg_temp.fid(30),pg_temp.fid(40),pg_temp.fid(10),'confirmed',2,1000);
select pg_temp.complete_fixture();
commit;
begin;
do $test$
declare report jsonb; rated jsonb; unrated jsonb;
begin
  perform set_config('request.jwt.claim.sub',pg_temp.fid(101)::text,true);
  perform public.v2_customer_submit_feedback(pg_temp.fid(80),5,10,5,4,5,5,null,null,false);
  perform public.v2_customer_submit_feedback(pg_temp.fid(82),5,0,5,5,5,5,null,null,false);
  update pace_v2.customer_feedback set created_at=now()-interval '45 days' where booking_id=pg_temp.fid(80);
  begin
    perform public.v2_site_admin_quality_dashboard();
    raise exception 'customer read site-admin quality report';
  exception when others then if sqlerrm<>'site admin required' then raise; end if; end;
  perform set_config('request.jwt.claim.sub',pg_temp.fid(100)::text,true);
  report:=public.v2_site_admin_quality_dashboard();
  select value into rated from jsonb_array_elements(report->'captains') where value->>'id'=pg_temp.fid(8)::text;
  select value into unrated from jsonb_array_elements(report->'captains') where value->>'id'=pg_temp.fid(9)::text;
  if (rated->>'average')::numeric<>4.5 or (rated->>'response_count')::integer<>2 then raise exception 'captain ratings 4 and 5 must aggregate to 4.5/5 with two responses'; end if;
  if unrated->>'average' is not null or (unrated->>'response_count')::integer<>0 then raise exception 'unrated captain must not have an invented score'; end if;
  if (rated->>'trend')::numeric<>1 or unrated->>'trend' is not null then raise exception 'captain trend must compare current and prior 30-day ratings without inventing unrated trend'; end if;
  if (report->'platform'->>'nps')::numeric<>0 then raise exception 'platform NPS should remain separate from captain rating'; end if;
end $test$;
rollback;
