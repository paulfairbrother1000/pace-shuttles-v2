-- Restore the bounded partner catalogue query that was unintentionally
-- replaced by the captain-duty migration.  The lateral eligibility helper is
-- correct for one departure, but invoking it for every future departure made
-- the public partner feed exceed the production statement timeout.
create or replace function public.v2_system_partner_shuttle_catalog(p_api_key text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $partner_catalogue$
declare
  v_partner pace_v2.api_partners%rowtype;
  v_recent_requests integer;
  v_tiles jsonb;
begin
  if nullif(trim(coalesce(p_api_key,'')),'') is null then
    return jsonb_build_object('authorized',false);
  end if;

  select * into v_partner
  from pace_v2.api_partners
  where api_key_hash=encode(extensions.digest(p_api_key,'sha256'),'hex')
    and active
  limit 1
  for update;

  if v_partner.id is null then
    return jsonb_build_object('authorized',false);
  end if;

  select count(*) into v_recent_requests
  from pace_v2.partner_api_requests
  where partner_id=v_partner.id
    and requested_at>=now()-interval '1 minute';

  if v_recent_requests>=v_partner.rate_limit_per_minute then
    return jsonb_build_object('authorized',true,'rate_limited',true);
  end if;

  insert into pace_v2.partner_api_requests(partner_id) values(v_partner.id);
  update pace_v2.api_partners
  set last_used_at=now(),updated_at=now()
  where id=v_partner.id;

  with viable as (
    select distinct on(d.route_id)
      d.route_id,
      d.scheduled_departure_ts,
      v.vehicle_type_id
    from pace_v2.departures d
    join pace_v2.routes r
      on r.id=d.route_id
      and r.is_active
      and r.country_id=v_partner.country_id
    join pace_v2.countries c
      on c.id=r.country_id
      and c.active
      and c.customer_availability_paused is not true
    join pace_v2.vehicle_route_offers vro
      on vro.service_id=d.service_id
      and vro.active
      and vro.effective_from<=d.scheduled_departure_ts
      and (vro.effective_to is null or vro.effective_to>d.scheduled_departure_ts)
    join pace_v2.vehicles v
      on v.id=vro.vehicle_id
      and v.active
    join pace_v2.operators o
      on o.id=v.operator_id
      and o.active
    join pace_v2.operator_vehicle_types ovt
      on ovt.operator_id=v.operator_id
      and ovt.vehicle_type_id=v.vehicle_type_id
      and ovt.status='approved'
    join pace_v2.route_vehicle_types rvt
      on rvt.route_id=d.route_id
      and rvt.vehicle_type_id=v.vehicle_type_id
      and rvt.active
      and rvt.effective_from<=d.scheduled_departure_ts
      and (rvt.effective_to is null or rvt.effective_to>d.scheduled_departure_ts)
    where d.is_commercial
      and d.scheduled_departure_ts>now()
      and d.status in('scheduled','selling','at_risk','under_consideration')
      and not exists (
        select 1
        from pace_v2.vehicle_availability_exceptions vae
        where vae.vehicle_id=v.id
          and vae.start_ts<coalesce(
            d.scheduled_arrival_ts,
            d.scheduled_departure_ts+interval '8 hours'
          )
          and vae.end_ts>d.scheduled_departure_ts
      )
    order by d.route_id,d.scheduled_departure_ts,v.vehicle_type_id
  )
  select coalesce(jsonb_agg(tile order by tile->>'route_name'),'[]'::jsonb)
  into v_tiles
  from (
    select jsonb_build_object(
      'route_id',r.id,
      'country',c.name,
      'vehicle_type',vt.name,
      'route_name',r.route_name,
      'pickup',jsonb_build_object(
        'id',p.id,
        'name',p.name,
        'image_url',p.picture_url
      ),
      'destination',jsonb_build_object(
        'id',dst.id,
        'name',dst.name,
        'image_url',dst.picture_url
      ),
      'schedule',nullif(trim(coalesce(r.frequency,'')),'')
    ) as tile
    from viable
    join pace_v2.routes r on r.id=viable.route_id and r.is_active
    join pace_v2.countries c
      on c.id=r.country_id
      and c.active
      and c.customer_availability_paused is not true
    join pace_v2.pickup_points p on p.id=r.pickup_id and p.active
    join pace_v2.destinations dst
      on dst.id=r.destination_id
      and dst.active
      and dst.published_at is not null
    join pace_v2.vehicle_types vt
      on vt.id=viable.vehicle_type_id
      and vt.active
  ) catalogue;

  return jsonb_build_object(
    'authorized',true,
    'partner',jsonb_build_object('id',v_partner.id,'name',v_partner.name),
    'country_id',v_partner.country_id,
    'tiles',v_tiles
  );
end
$partner_catalogue$;

-- Long-horizon generation used to attempt the complete 41-day recovery band
-- in every hourly transaction.  A cold backlog could not commit before the
-- statement timeout, so every retry started the same work again.  Generate
-- the earliest missing service date only; hourly runs then make durable,
-- bounded progress while still performing due operational phases each run.
create or replace function public.v2_system_run_scheduled_operations(
  p_t72_limit integer default 50,
  p_t24_limit integer default 50
)
returns jsonb
language plpgsql
security definer
set search_path='public','pace_v2'
as $scheduled_operations$
declare
  r record;
  v_t72 integer:=0;
  v_t24 integer:=0;
  v_failed integer:=0;
  v_generated integer:=0;
  v_generation_date date;
  v_result jsonb;
begin
  with horizon_dates as (
    select generated_at::date as service_date
    from generate_series(
      current_date+340,
      current_date+380,
      interval '1 day'
    ) generated_at
  )
  select h.service_date into v_generation_date
  from horizon_dates h
  where exists (
    select 1
    from pace_v2.services s
    where s.active
      and (s.valid_from is null or s.valid_from<=h.service_date)
      and (s.valid_to is null or s.valid_to>=h.service_date)
      and extract(isodow from h.service_date)::smallint=any(s.days_of_week)
      and (
        s.recurrence_interval_weeks=1
        or s.recurrence_anchor_date is null
        or floor((h.service_date-s.recurrence_anchor_date)::numeric/7)::integer
          % s.recurrence_interval_weeks=0
      )
      and not exists (
        select 1
        from pace_v2.departures d
        where d.service_id=s.id
          and d.local_departure_date=h.service_date
      )
  )
  order by h.service_date
  limit 1;

  if v_generation_date is not null then
    select count(*) filter(where g.inserted) into v_generated
    from pace_v2.generate_departures(v_generation_date,v_generation_date) g;
  end if;

  for r in
    select d.id
    from pace_v2.departures d
    where d.t72_ts<=now()
      and d.t24_ts>now()
      and d.status not in('completed','cancelled','confirmed')
      and not exists (
        select 1
        from pace_v2.scheduled_job_runs j
        where j.departure_id=d.id and j.phase='t72'
      )
    order by d.t72_ts
    limit greatest(1,least(coalesce(p_t72_limit,50),200))
  loop
    begin
      v_result:=pace_v2.process_departure_t72(r.id,'cron-v1.0',false);
      v_t72:=v_t72+1;
    exception when others then
      v_failed:=v_failed+1;
    end;
  end loop;

  for r in
    select d.id
    from pace_v2.departures d
    where d.t24_ts<=now()
      and d.status not in('completed','cancelled','confirmed')
      and not exists (
        select 1
        from pace_v2.scheduled_job_runs j
        where j.departure_id=d.id and j.phase='t24'
      )
    order by d.t24_ts
    limit greatest(1,least(coalesce(p_t24_limit,50),200))
  loop
    begin
      v_result:=pace_v2.process_departure_t24(r.id,'cron-v1.0',false);
      v_t24:=v_t24+1;
    exception when others then
      v_failed:=v_failed+1;
    end;
  end loop;

  return jsonb_build_object(
    'generated_departures',v_generated,
    'generation_date',v_generation_date,
    't72_processed',v_t72,
    't24_processed',v_t24,
    'failed',v_failed,
    'ran_at',now()
  );
end
$scheduled_operations$;

revoke all on function public.v2_system_partner_shuttle_catalog(text) from public,anon,authenticated;
revoke all on function public.v2_system_run_scheduled_operations(integer,integer) from public,anon,authenticated;
grant execute on function public.v2_system_partner_shuttle_catalog(text) to service_role;
grant execute on function public.v2_system_run_scheduled_operations(integer,integer) to service_role;
