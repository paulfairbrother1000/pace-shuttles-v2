begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(5);

do $fixture$
declare
  source_departure pace_v2.departures%rowtype;
begin
  select * into source_departure from pace_v2.departures
  where service_id is not null order by scheduled_departure_ts limit 1;
  if source_departure.id is null then raise exception 'service departure fixture required'; end if;

  -- Scope the protected pairing context to fixture setup in this transaction.
  perform set_config('pace_v2.journey_pair_mutation_authorized','on',true);

  insert into pace_v2.departures (
    id,service_id,route_id,scheduled_departure_ts,scheduled_arrival_ts,
    trip_timezone,local_departure_date,t72_ts,t24_ts,status,
    is_commercial,leg_number,journey_pair_id
  )
  select row.id,source_departure.service_id,source_departure.route_id,
    row.fixture_date::timestamptz,row.arrival_at,
    source_departure.trip_timezone,row.fixture_date,
    row.fixture_date::timestamptz-interval '72 hours',row.fixture_date::timestamptz-interval '24 hours',
    row.status::pace_v2.departure_status,row.is_commercial,row.leg,
    row.pair_id
  from (values
    ('f0000000-0000-0000-0000-000000000101'::uuid,'f0000000-0000-0000-0000-000000000201'::uuid,2,false,'scheduled','2020-01-01'::date,'2020-01-01 13:00:00+00'::timestamptz),
    ('f0000000-0000-0000-0000-000000000102'::uuid,'f0000000-0000-0000-0000-000000000202'::uuid,2,false,'scheduled','2020-01-02'::date,now()-interval '4 hours'),
    ('f0000000-0000-0000-0000-000000000103'::uuid,'f0000000-0000-0000-0000-000000000203'::uuid,2,false,'completed','2020-01-03'::date,'2020-01-03 13:00:00+00'::timestamptz),
    ('f0000000-0000-0000-0000-000000000104'::uuid,'f0000000-0000-0000-0000-000000000204'::uuid,1,true,'scheduled','2020-01-04'::date,'2020-01-04 13:00:00+00'::timestamptz),
    ('f0000000-0000-0000-0000-000000000105'::uuid,'f0000000-0000-0000-0000-000000000204'::uuid,2,false,'scheduled','2020-01-05'::date,'2020-01-05 13:00:00+00'::timestamptz)
  ) row(id,pair_id,leg,is_commercial,status,fixture_date,arrival_at);

  insert into pace_v2.bookings(departure_id,route_id,customer_name,seats,unit_price_cents,total_price_cents,status)
  values('f0000000-0000-0000-0000-000000000104',source_departure.route_id,'Fixture passenger',1,10000,10000,'booked');
  perform set_config('pace_v2.journey_pair_mutation_authorized','off',true);
end
$fixture$;

select public.v2_system_reconcile_empty_paired_returns(1000);
select extensions.is((select status::text from pace_v2.departures where id='f0000000-0000-0000-0000-000000000101'),'cancelled','expired empty return is cancelled');
select extensions.is((select cancelled_reason from pace_v2.departures where id='f0000000-0000-0000-0000-000000000101'),'Closed after departure — no paired bookings.','empty return has an explicit reason');
select extensions.is((select status::text from pace_v2.departures where id='f0000000-0000-0000-0000-000000000102'),'scheduled','return within outcome grace period stays open');
select extensions.is((select status::text from pace_v2.departures where id='f0000000-0000-0000-0000-000000000103'),'completed','completed return is preserved');
select extensions.is((select status::text from pace_v2.departures where id='f0000000-0000-0000-0000-000000000105'),'scheduled','booked paired return remains for existing unrecorded-outcome reconciliation');
do $assert$
begin
 if (select status::text from pace_v2.departures where id='f0000000-0000-0000-0000-000000000101')<>'cancelled'
 or (select status::text from pace_v2.departures where id='f0000000-0000-0000-0000-000000000102')<>'scheduled'
 or (select status::text from pace_v2.departures where id='f0000000-0000-0000-0000-000000000103')<>'completed'
 or (select status::text from pace_v2.departures where id='f0000000-0000-0000-0000-000000000105')<>'scheduled' then
   raise exception 'paired return lifecycle regression';
 end if;
end
$assert$;
select extensions.finish();
rollback;
