begin;
do $$ declare v_country uuid; begin
 select id into v_country from pace_v2.countries limit 1;
 if v_country is not null then
  update pace_v2.countries set customer_availability_paused=true,customer_pause_reason='transactional availability test' where id=v_country;
  if exists(select 1 from public.v2_public_departures where country_id=v_country) then raise exception 'paused country still has public departures';end if;
 end if;
end $$;
rollback;
