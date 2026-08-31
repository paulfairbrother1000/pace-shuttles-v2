-- Additive V2 feedback/quality migration. The production finance/quality migration
-- predates the repository DDL, so every shared structure is extended in place.
create table if not exists pace_v2.quality_configuration(
  config_key text primary key,
  operator_rating_weight numeric(5,4) not null default 0.60,
  captain_rating_weight numeric(5,4) not null default 0.40,
  evidence_decay_half_life_days integer not null default 180,
  updated_at timestamptz not null default now()
);
alter table pace_v2.quality_configuration add column if not exists config_key text;
alter table pace_v2.quality_configuration add column if not exists operator_rating_weight numeric(5,4) not null default 0.60;
alter table pace_v2.quality_configuration add column if not exists captain_rating_weight numeric(5,4) not null default 0.40;
alter table pace_v2.quality_configuration add column if not exists evidence_decay_half_life_days integer not null default 180;
alter table pace_v2.quality_configuration add column if not exists updated_at timestamptz not null default now();

-- Derive the shape of a plain default-btree declaration from PostgreSQL's
-- catalogs. No template index is built on a populated production table.
create or replace function pace_v2._feedback_unique_index_matches(
  p_index_oid oid,
  p_table_oid oid,
  p_column_names text[],
  p_expected_predicate text default null,
  p_accept_nonpartial boolean default false,
  p_nulls_not_distinct boolean default false,
  p_immediate boolean default true
) returns boolean
language plpgsql stable set search_path=pg_catalog as $index_shape$
declare
  v_btree_method oid;
  v_expected_count integer;
  v_expected_keys smallint[];
  v_expected_opclasses oid[];
  v_expected_collations oid[];
  v_expected_options smallint[];
begin
  if p_index_oid is null or p_table_oid is null or cardinality(p_column_names)=0 then return false; end if;
  select am.oid into strict v_btree_method from pg_am am where am.amname='btree';
  select count(*)::integer,
         array_agg(attribute.attnum::smallint order by requested.position),
         array_agg(default_opclass.oid order by requested.position),
         array_agg(attribute.attcollation order by requested.position),
         array_agg(0::smallint order by requested.position)
  into v_expected_count,v_expected_keys,v_expected_opclasses,v_expected_collations,v_expected_options
  from unnest(p_column_names) with ordinality requested(column_name,position)
  join pg_attribute attribute on attribute.attrelid=p_table_oid and attribute.attname=requested.column_name and not attribute.attisdropped
  join lateral(
    select opclass.oid
    from pg_opclass opclass
    where opclass.opcmethod=v_btree_method and opclass.opcdefault
      and (opclass.opcintype=attribute.atttypid or exists(
        select 1 from pg_cast cast_entry
        where cast_entry.castsource=attribute.atttypid and cast_entry.casttarget=opclass.opcintype
          and cast_entry.castmethod='b' and cast_entry.castcontext in('i','a')
      ))
    order by (opclass.opcintype=attribute.atttypid) desc,opclass.oid
    limit 1
  ) default_opclass on true;
  if v_expected_count<>cardinality(p_column_names) then
    raise exception 'cannot derive default btree index shape for %.%',p_table_oid::regclass,p_column_names;
  end if;
  return exists(
    select 1
    from pg_index candidate
    join pg_class index_class on index_class.oid=candidate.indexrelid
    where candidate.indexrelid=p_index_oid and candidate.indrelid=p_table_oid
      and index_class.relam=v_btree_method
      and candidate.indisunique and candidate.indisvalid and candidate.indisready and candidate.indislive
      and candidate.indimmediate=p_immediate and not candidate.indisexclusion
      and candidate.indnullsnotdistinct=p_nulls_not_distinct and candidate.indexprs is null
      and candidate.indnkeyatts=v_expected_count and candidate.indnatts=v_expected_count
      and (select array_agg(entry.value order by entry.position) from unnest(candidate.indkey::smallint[]) with ordinality entry(value,position))=v_expected_keys
      and (select array_agg(entry.value order by entry.position) from unnest(candidate.indclass::oid[]) with ordinality entry(value,position))=v_expected_opclasses
      and (select array_agg(entry.value order by entry.position) from unnest(candidate.indcollation::oid[]) with ordinality entry(value,position))=v_expected_collations
      and (select array_agg(entry.value order by entry.position) from unnest(candidate.indoption::smallint[]) with ordinality entry(value,position))=v_expected_options
      and (
        (p_expected_predicate is null and candidate.indpred is null)
        or (p_expected_predicate is not null and (
          pg_get_expr(candidate.indpred,candidate.indrelid,false)=p_expected_predicate
          or (p_accept_nonpartial and candidate.indpred is null)
        ))
      )
  );
end
$index_shape$;

do $$
declare v_owned oid:=to_regclass('pace_v2.quality_configuration_config_key_key');
begin
  if v_owned is not null and not pace_v2._feedback_unique_index_matches(v_owned,'pace_v2.quality_configuration'::regclass,array['config_key']) then raise exception 'unique index % is owned with an incompatible definition','quality_configuration_config_key_key'; end if;
  if not exists(select 1 from pg_index i where pace_v2._feedback_unique_index_matches(i.indexrelid,'pace_v2.quality_configuration'::regclass,array['config_key'])) then create unique index quality_configuration_config_key_key on pace_v2.quality_configuration(config_key); end if;
end $$;

do $$
declare v_check record; v_temp_name text; v_expected_bin text; v_owned record;
begin
  for v_check in select * from (values
    ('quality_configuration_feedback_weights_check','operator_rating_weight between 0 and 1 and captain_rating_weight between 0 and 1 and operator_rating_weight+captain_rating_weight=1'),
    ('quality_configuration_decay_check','evidence_decay_half_life_days between 1 and 3650')
  ) as expected(constraint_name,expression_sql)
  loop
    v_temp_name:=v_check.constraint_name||'_expected';
    execute format('alter table pace_v2.quality_configuration add constraint %I check(%s) not valid',v_temp_name,v_check.expression_sql);
    select conbin::text into v_expected_bin from pg_constraint where conrelid='pace_v2.quality_configuration'::regclass and conname=v_temp_name;
    select c.oid,c.conbin,c.connoinherit into v_owned from pg_constraint c where c.conrelid='pace_v2.quality_configuration'::regclass and c.conname=v_check.constraint_name;
    if v_owned.oid is not null and (v_owned.conbin::text is distinct from v_expected_bin or v_owned.connoinherit) then raise exception 'check constraint % is owned with an incompatible definition',v_check.constraint_name; end if;
    if v_owned.oid is not null or exists(select 1 from pg_constraint c where c.conrelid='pace_v2.quality_configuration'::regclass and c.contype='c' and not c.connoinherit and c.conname<>v_temp_name and c.conbin::text=v_expected_bin) then
      execute format('alter table pace_v2.quality_configuration drop constraint %I',v_temp_name);
    else
      execute format('alter table pace_v2.quality_configuration rename constraint %I to %I',v_temp_name,v_check.constraint_name);
    end if;
  end loop;
end $$;

insert into pace_v2.quality_configuration(config_key,operator_rating_weight,captain_rating_weight,evidence_decay_half_life_days)
values('journey_feedback',0.60,0.40,180)
on conflict(config_key) do nothing;

create table if not exists pace_v2.customer_feedback(
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references pace_v2.bookings(id),
  departure_id uuid references pace_v2.departures(id),
  confirmed_allocation_id uuid references pace_v2.confirmed_allocations(id),
  operator_id uuid references pace_v2.operators(id),
  vehicle_id uuid references pace_v2.vehicles(id),
  captain_id uuid references pace_v2.captains(id),
  pickup_id uuid references pace_v2.pickup_points(id),
  destination_id uuid references pace_v2.destinations(id),
  submitted_by uuid references auth.users(id),
  booking_experience_rating integer,
  pace_shuttles_nps_score integer,
  operator_rating integer,
  captain_rating integer,
  pickup_rating integer,
  destination_rating integer,
  went_well text,
  could_improve text,
  testimonial_consent boolean not null default false,
  feedback_schema_version integer not null default 2,
  created_at timestamptz not null default now(),
  constraint customer_feedback_booking_key unique(booking_id)
);

alter table pace_v2.customer_feedback add column if not exists departure_id uuid references pace_v2.departures(id);
alter table pace_v2.customer_feedback add column if not exists confirmed_allocation_id uuid references pace_v2.confirmed_allocations(id);
alter table pace_v2.customer_feedback add column if not exists operator_id uuid references pace_v2.operators(id);
alter table pace_v2.customer_feedback add column if not exists vehicle_id uuid references pace_v2.vehicles(id);
alter table pace_v2.customer_feedback add column if not exists captain_id uuid references pace_v2.captains(id);
alter table pace_v2.customer_feedback add column if not exists pickup_id uuid references pace_v2.pickup_points(id);
alter table pace_v2.customer_feedback add column if not exists destination_id uuid references pace_v2.destinations(id);
alter table pace_v2.customer_feedback add column if not exists submitted_by uuid references auth.users(id);
alter table pace_v2.customer_feedback add column if not exists booking_experience_rating integer;
alter table pace_v2.customer_feedback add column if not exists pace_shuttles_nps_score integer;
alter table pace_v2.customer_feedback add column if not exists operator_rating integer;
alter table pace_v2.customer_feedback add column if not exists captain_rating integer;
alter table pace_v2.customer_feedback add column if not exists pickup_rating integer;
alter table pace_v2.customer_feedback add column if not exists destination_rating integer;
alter table pace_v2.customer_feedback add column if not exists went_well text;
alter table pace_v2.customer_feedback add column if not exists could_improve text;
alter table pace_v2.customer_feedback add column if not exists testimonial_consent boolean;
alter table pace_v2.customer_feedback add column if not exists feedback_schema_version integer default 1;
update pace_v2.customer_feedback set testimonial_consent=false where testimonial_consent is null;
alter table pace_v2.customer_feedback alter column testimonial_consent set default false;
alter table pace_v2.customer_feedback alter column testimonial_consent set not null;
update pace_v2.customer_feedback set feedback_schema_version=1 where feedback_schema_version is null;
alter table pace_v2.customer_feedback alter column feedback_schema_version set default 2;
alter table pace_v2.customer_feedback alter column feedback_schema_version set not null;
do $$
declare v_owned oid:=to_regclass('pace_v2.customer_feedback_one_response_per_booking');
begin
  if v_owned is not null and not pace_v2._feedback_unique_index_matches(v_owned,'pace_v2.customer_feedback'::regclass,array['booking_id']) then raise exception 'unique index % is owned with an incompatible definition','customer_feedback_one_response_per_booking'; end if;
  if not exists(select 1 from pg_index i where pace_v2._feedback_unique_index_matches(i.indexrelid,'pace_v2.customer_feedback'::regclass,array['booking_id'])) then create unique index customer_feedback_one_response_per_booking on pace_v2.customer_feedback(booking_id); end if;
end $$;

do $$
declare v_column text; v_check record; v_temp_name text; v_expected_bin text; v_owned record;
begin
  if not exists(select 1 from information_schema.columns where table_schema='pace_v2' and table_name='customer_feedback' and column_name='testimonial_consent' and data_type='boolean') then raise exception 'pace_v2.customer_feedback.testimonial_consent must be boolean'; end if;
  if not exists(select 1 from information_schema.columns where table_schema='pace_v2' and table_name='customer_feedback' and column_name='feedback_schema_version' and data_type in('smallint','integer','bigint')) then raise exception 'pace_v2.customer_feedback.feedback_schema_version must be integer-compatible'; end if;
  foreach v_column in array array['booking_experience_rating','pace_shuttles_nps_score','operator_rating','captain_rating','pickup_rating','destination_rating'] loop
    if not exists(select 1 from information_schema.columns where table_schema='pace_v2' and table_name='customer_feedback' and column_name=v_column and data_type in('smallint','integer','bigint','numeric')) then
      raise exception 'pace_v2.customer_feedback.% must be a numeric rating column',v_column;
    end if;
  end loop;
  foreach v_column in array array['booking_experience_rating','operator_rating','captain_rating','pickup_rating','destination_rating'] loop execute format('alter table pace_v2.customer_feedback drop constraint if exists %I','customer_feedback_'||v_column||'_check'); end loop;
  alter table pace_v2.customer_feedback drop constraint if exists customer_feedback_nps_check;
  for v_check in select * from (values
    ('customer_feedback_v2_booking_experience_rating_check','feedback_schema_version<2 or (booking_experience_rating between 1 and 5 and booking_experience_rating::numeric=trunc(booking_experience_rating::numeric))'),
    ('customer_feedback_v2_operator_rating_check','feedback_schema_version<2 or (operator_rating between 1 and 5 and operator_rating::numeric=trunc(operator_rating::numeric))'),
    ('customer_feedback_v2_captain_rating_check','feedback_schema_version<2 or (captain_rating between 1 and 5 and captain_rating::numeric=trunc(captain_rating::numeric))'),
    ('customer_feedback_v2_pickup_rating_check','feedback_schema_version<2 or (pickup_rating between 1 and 5 and pickup_rating::numeric=trunc(pickup_rating::numeric))'),
    ('customer_feedback_v2_destination_rating_check','feedback_schema_version<2 or (destination_rating between 1 and 5 and destination_rating::numeric=trunc(destination_rating::numeric))'),
    ('customer_feedback_v2_nps_check','feedback_schema_version<2 or (pace_shuttles_nps_score between 0 and 10 and pace_shuttles_nps_score::numeric=trunc(pace_shuttles_nps_score::numeric))'),
    ('customer_feedback_v2_required_ratings_check','feedback_schema_version<2 or (booking_experience_rating is not null and pace_shuttles_nps_score is not null and operator_rating is not null and captain_rating is not null and pickup_rating is not null and destination_rating is not null)')
  ) as expected(constraint_name,expression_sql)
  loop
    v_temp_name:=left(v_check.constraint_name,54)||'_expected';
    execute format('alter table pace_v2.customer_feedback add constraint %I check(%s) not valid',v_temp_name,v_check.expression_sql);
    select conbin::text into v_expected_bin from pg_constraint where conrelid='pace_v2.customer_feedback'::regclass and conname=v_temp_name;
    select c.oid,c.conbin,c.connoinherit into v_owned from pg_constraint c where c.conrelid='pace_v2.customer_feedback'::regclass and c.conname=v_check.constraint_name;
    if v_owned.oid is not null and (v_owned.conbin::text is distinct from v_expected_bin or v_owned.connoinherit) then raise exception 'check constraint % is owned with an incompatible definition',v_check.constraint_name; end if;
    if v_owned.oid is not null or exists(select 1 from pg_constraint c where c.conrelid='pace_v2.customer_feedback'::regclass and c.contype='c' and not c.connoinherit and c.conname<>v_temp_name and c.conbin::text=v_expected_bin) then
      execute format('alter table pace_v2.customer_feedback drop constraint %I',v_temp_name);
    else
      execute format('alter table pace_v2.customer_feedback rename constraint %I to %I',v_temp_name,v_check.constraint_name);
    end if;
  end loop;
end $$;

create table if not exists pace_v2.quality_evidence(
  id uuid primary key default gen_random_uuid(),
  feedback_id uuid not null references pace_v2.customer_feedback(id),
  booking_id uuid not null references pace_v2.bookings(id),
  departure_id uuid not null references pace_v2.departures(id),
  confirmed_allocation_id uuid not null references pace_v2.confirmed_allocations(id),
  operator_id uuid references pace_v2.operators(id),
  vehicle_id uuid references pace_v2.vehicles(id),
  captain_id uuid references pace_v2.captains(id),
  pickup_id uuid references pace_v2.pickup_points(id),
  destination_id uuid references pace_v2.destinations(id),
  dimension text not null,
  rating numeric(8,4) not null,
  rating_effect numeric(8,4) not null,
  operator_score_effect numeric(8,4) not null default 0,
  evidence_weight numeric(8,4) not null default 1,
  decay_half_life_days integer not null default 180,
  source_attribution text not null default 'unreviewed',
  occurred_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint quality_evidence_feedback_dimension_key unique(feedback_id,dimension)
);
alter table pace_v2.quality_evidence add column if not exists feedback_id uuid references pace_v2.customer_feedback(id);
alter table pace_v2.quality_evidence add column if not exists booking_id uuid references pace_v2.bookings(id);
alter table pace_v2.quality_evidence add column if not exists departure_id uuid references pace_v2.departures(id);
alter table pace_v2.quality_evidence add column if not exists confirmed_allocation_id uuid references pace_v2.confirmed_allocations(id);
alter table pace_v2.quality_evidence add column if not exists operator_id uuid references pace_v2.operators(id);
alter table pace_v2.quality_evidence add column if not exists vehicle_id uuid references pace_v2.vehicles(id);
alter table pace_v2.quality_evidence add column if not exists captain_id uuid references pace_v2.captains(id);
alter table pace_v2.quality_evidence add column if not exists pickup_id uuid references pace_v2.pickup_points(id);
alter table pace_v2.quality_evidence add column if not exists destination_id uuid references pace_v2.destinations(id);
alter table pace_v2.quality_evidence add column if not exists dimension text;
alter table pace_v2.quality_evidence add column if not exists rating numeric(8,4);
alter table pace_v2.quality_evidence add column if not exists rating_effect numeric(8,4);
alter table pace_v2.quality_evidence add column if not exists operator_score_effect numeric(8,4) not null default 0;
alter table pace_v2.quality_evidence add column if not exists evidence_weight numeric(8,4) not null default 1;
alter table pace_v2.quality_evidence add column if not exists decay_half_life_days integer not null default 180;
alter table pace_v2.quality_evidence add column if not exists source_attribution text not null default 'unreviewed';
alter table pace_v2.quality_evidence add column if not exists occurred_at timestamptz;
do $$
declare v_owned oid:=to_regclass('pace_v2.quality_evidence_feedback_dimension_key');
begin
  if v_owned is not null and not pace_v2._feedback_unique_index_matches(v_owned,'pace_v2.quality_evidence'::regclass,array['feedback_id','dimension']) then raise exception 'unique index % is owned with an incompatible definition','quality_evidence_feedback_dimension_key'; end if;
  if not exists(select 1 from pg_index i where pace_v2._feedback_unique_index_matches(i.indexrelid,'pace_v2.quality_evidence'::regclass,array['feedback_id','dimension'])) then create unique index quality_evidence_feedback_dimension_key on pace_v2.quality_evidence(feedback_id,dimension); end if;
end $$;

create table if not exists pace_v2.platform_quality_history(
  id uuid primary key default gen_random_uuid(),feedback_id uuid not null references pace_v2.customer_feedback(id),
  booking_id uuid not null references pace_v2.bookings(id),dimension text not null check(dimension in('booking_experience','pace_shuttles_nps')),
  rating integer not null,rating_effect numeric(8,4) not null,operator_score_effect numeric(8,4) not null default 0 check(operator_score_effect=0),
  occurred_at timestamptz not null,created_at timestamptz not null default now(),unique(feedback_id,dimension)
);
create table if not exists pace_v2.captain_quality_history(
  id uuid primary key default gen_random_uuid(),feedback_id uuid not null unique references pace_v2.customer_feedback(id),booking_id uuid not null references pace_v2.bookings(id),
  departure_id uuid not null references pace_v2.departures(id),captain_id uuid not null references pace_v2.captains(id),rating integer not null check(rating between 1 and 5),
  rating_effect numeric(8,4) not null,occurred_at timestamptz not null,created_at timestamptz not null default now()
);
create table if not exists pace_v2.pickup_quality_history(
  id uuid primary key default gen_random_uuid(),feedback_id uuid not null unique references pace_v2.customer_feedback(id),booking_id uuid not null references pace_v2.bookings(id),
  departure_id uuid not null references pace_v2.departures(id),pickup_id uuid not null references pace_v2.pickup_points(id),rating integer not null check(rating between 1 and 5),
  rating_effect numeric(8,4) not null,occurred_at timestamptz not null,created_at timestamptz not null default now()
);
create table if not exists pace_v2.destination_quality_history(
  id uuid primary key default gen_random_uuid(),feedback_id uuid not null unique references pace_v2.customer_feedback(id),booking_id uuid not null references pace_v2.bookings(id),
  departure_id uuid not null references pace_v2.departures(id),destination_id uuid not null references pace_v2.destinations(id),rating integer not null check(rating between 1 and 5),
  rating_effect numeric(8,4) not null,occurred_at timestamptz not null,created_at timestamptz not null default now()
);

alter table pace_v2.platform_quality_history add column if not exists id uuid default gen_random_uuid();
alter table pace_v2.platform_quality_history add column if not exists feedback_id uuid;
alter table pace_v2.platform_quality_history add column if not exists booking_id uuid;
alter table pace_v2.platform_quality_history add column if not exists dimension text;
alter table pace_v2.platform_quality_history add column if not exists rating integer;
alter table pace_v2.platform_quality_history add column if not exists rating_effect numeric(8,4);
alter table pace_v2.platform_quality_history add column if not exists operator_score_effect numeric(8,4) default 0;
alter table pace_v2.platform_quality_history add column if not exists occurred_at timestamptz;
alter table pace_v2.platform_quality_history add column if not exists created_at timestamptz default now();
do $$
declare v_column text;
begin
  foreach v_column in array array['id','feedback_id','booking_id'] loop
    if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name='platform_quality_history' and column_name=v_column)<>'uuid' then raise exception 'pace_v2.platform_quality_history.% must be uuid',v_column; end if;
  end loop;
  foreach v_column in array array['rating','rating_effect','operator_score_effect'] loop
    if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name='platform_quality_history' and column_name=v_column) not in('smallint','integer','bigint','numeric') then raise exception 'pace_v2.platform_quality_history.% must be numeric',v_column; end if;
  end loop;
  foreach v_column in array array['occurred_at','created_at'] loop
    if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name='platform_quality_history' and column_name=v_column)<>'timestamp with time zone' then raise exception 'pace_v2.platform_quality_history.% must be timestamptz',v_column; end if;
  end loop;
  if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name='platform_quality_history' and column_name='dimension') not in('text','character varying','character') then raise exception 'pace_v2.platform_quality_history.dimension must be text-compatible'; end if;
end $$;
update pace_v2.platform_quality_history set id=gen_random_uuid() where id is null;
update pace_v2.platform_quality_history set operator_score_effect=0 where operator_score_effect is null;
update pace_v2.platform_quality_history set created_at=now() where created_at is null;
alter table pace_v2.platform_quality_history alter column id set default gen_random_uuid();
alter table pace_v2.platform_quality_history alter column id set not null;
alter table pace_v2.platform_quality_history alter column operator_score_effect set default 0;
alter table pace_v2.platform_quality_history alter column operator_score_effect set not null;
alter table pace_v2.platform_quality_history alter column created_at set default now();
alter table pace_v2.platform_quality_history alter column created_at set not null;

alter table pace_v2.captain_quality_history add column if not exists id uuid default gen_random_uuid();
alter table pace_v2.captain_quality_history add column if not exists feedback_id uuid;
alter table pace_v2.captain_quality_history add column if not exists booking_id uuid;
alter table pace_v2.captain_quality_history add column if not exists departure_id uuid;
alter table pace_v2.captain_quality_history add column if not exists captain_id uuid;
alter table pace_v2.captain_quality_history add column if not exists rating integer;
alter table pace_v2.captain_quality_history add column if not exists rating_effect numeric(8,4);
alter table pace_v2.captain_quality_history add column if not exists occurred_at timestamptz;
alter table pace_v2.captain_quality_history add column if not exists created_at timestamptz default now();
do $$
declare v_column text;
begin
  foreach v_column in array array['id','feedback_id','booking_id','departure_id','captain_id'] loop
    if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name='captain_quality_history' and column_name=v_column)<>'uuid' then raise exception 'pace_v2.captain_quality_history.% must be uuid',v_column; end if;
  end loop;
  foreach v_column in array array['rating','rating_effect'] loop
    if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name='captain_quality_history' and column_name=v_column) not in('smallint','integer','bigint','numeric') then raise exception 'pace_v2.captain_quality_history.% must be numeric',v_column; end if;
  end loop;
  foreach v_column in array array['occurred_at','created_at'] loop
    if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name='captain_quality_history' and column_name=v_column)<>'timestamp with time zone' then raise exception 'pace_v2.captain_quality_history.% must be timestamptz',v_column; end if;
  end loop;
end $$;
update pace_v2.captain_quality_history set id=gen_random_uuid() where id is null;
update pace_v2.captain_quality_history set created_at=now() where created_at is null;
alter table pace_v2.captain_quality_history alter column id set default gen_random_uuid();
alter table pace_v2.captain_quality_history alter column id set not null;
alter table pace_v2.captain_quality_history alter column created_at set default now();
alter table pace_v2.captain_quality_history alter column created_at set not null;

alter table pace_v2.pickup_quality_history add column if not exists id uuid default gen_random_uuid();
alter table pace_v2.pickup_quality_history add column if not exists feedback_id uuid;
alter table pace_v2.pickup_quality_history add column if not exists booking_id uuid;
alter table pace_v2.pickup_quality_history add column if not exists departure_id uuid;
alter table pace_v2.pickup_quality_history add column if not exists pickup_id uuid;
alter table pace_v2.pickup_quality_history add column if not exists rating integer;
alter table pace_v2.pickup_quality_history add column if not exists rating_effect numeric(8,4);
alter table pace_v2.pickup_quality_history add column if not exists occurred_at timestamptz;
alter table pace_v2.pickup_quality_history add column if not exists created_at timestamptz default now();
do $$
declare v_column text;
begin
  foreach v_column in array array['id','feedback_id','booking_id','departure_id','pickup_id'] loop
    if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name='pickup_quality_history' and column_name=v_column)<>'uuid' then raise exception 'pace_v2.pickup_quality_history.% must be uuid',v_column; end if;
  end loop;
  foreach v_column in array array['rating','rating_effect'] loop
    if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name='pickup_quality_history' and column_name=v_column) not in('smallint','integer','bigint','numeric') then raise exception 'pace_v2.pickup_quality_history.% must be numeric',v_column; end if;
  end loop;
  foreach v_column in array array['occurred_at','created_at'] loop
    if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name='pickup_quality_history' and column_name=v_column)<>'timestamp with time zone' then raise exception 'pace_v2.pickup_quality_history.% must be timestamptz',v_column; end if;
  end loop;
end $$;
update pace_v2.pickup_quality_history set id=gen_random_uuid() where id is null;
update pace_v2.pickup_quality_history set created_at=now() where created_at is null;
alter table pace_v2.pickup_quality_history alter column id set default gen_random_uuid();
alter table pace_v2.pickup_quality_history alter column id set not null;
alter table pace_v2.pickup_quality_history alter column created_at set default now();
alter table pace_v2.pickup_quality_history alter column created_at set not null;

alter table pace_v2.destination_quality_history add column if not exists id uuid default gen_random_uuid();
alter table pace_v2.destination_quality_history add column if not exists feedback_id uuid;
alter table pace_v2.destination_quality_history add column if not exists booking_id uuid;
alter table pace_v2.destination_quality_history add column if not exists departure_id uuid;
alter table pace_v2.destination_quality_history add column if not exists destination_id uuid;
alter table pace_v2.destination_quality_history add column if not exists rating integer;
alter table pace_v2.destination_quality_history add column if not exists rating_effect numeric(8,4);
alter table pace_v2.destination_quality_history add column if not exists occurred_at timestamptz;
alter table pace_v2.destination_quality_history add column if not exists created_at timestamptz default now();
do $$
declare v_column text;
begin
  foreach v_column in array array['id','feedback_id','booking_id','departure_id','destination_id'] loop
    if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name='destination_quality_history' and column_name=v_column)<>'uuid' then raise exception 'pace_v2.destination_quality_history.% must be uuid',v_column; end if;
  end loop;
  foreach v_column in array array['rating','rating_effect'] loop
    if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name='destination_quality_history' and column_name=v_column) not in('smallint','integer','bigint','numeric') then raise exception 'pace_v2.destination_quality_history.% must be numeric',v_column; end if;
  end loop;
  foreach v_column in array array['occurred_at','created_at'] loop
    if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name='destination_quality_history' and column_name=v_column)<>'timestamp with time zone' then raise exception 'pace_v2.destination_quality_history.% must be timestamptz',v_column; end if;
  end loop;
end $$;
update pace_v2.destination_quality_history set id=gen_random_uuid() where id is null;
update pace_v2.destination_quality_history set created_at=now() where created_at is null;
alter table pace_v2.destination_quality_history alter column id set default gen_random_uuid();
alter table pace_v2.destination_quality_history alter column id set not null;
alter table pace_v2.destination_quality_history alter column created_at set default now();
alter table pace_v2.destination_quality_history alter column created_at set not null;

do $$
declare
  v_pk record; v_fk record; v_check record; v_owned record; v_table_oid oid; v_target_oid oid;
  v_column_attnum smallint; v_target_attnum smallint; v_temp_name text; v_expected_bin text;
begin
  for v_pk in select * from (values
    ('platform_quality_history','platform_quality_history_pkey'),('captain_quality_history','captain_quality_history_pkey'),
    ('pickup_quality_history','pickup_quality_history_pkey'),('destination_quality_history','destination_quality_history_pkey')
  ) as expected(table_name,constraint_name)
  loop
    v_table_oid:=to_regclass('pace_v2.'||v_pk.table_name);
    select attnum into strict v_column_attnum from pg_attribute where attrelid=v_table_oid and attname='id' and not attisdropped;
    select c.oid,c.contype,c.conkey,c.condeferrable into v_owned from pg_constraint c where c.conrelid=v_table_oid and c.conname=v_pk.constraint_name;
    if v_owned.oid is not null and not (v_owned.contype='p' and v_owned.conkey=array[v_column_attnum]::smallint[] and not v_owned.condeferrable) then raise exception 'primary key constraint % is owned with an incompatible definition',v_pk.constraint_name; end if;
    if v_owned.oid is not null or exists(select 1 from pg_constraint c where c.conrelid=v_table_oid and c.contype='p' and c.conkey=array[v_column_attnum]::smallint[] and not c.condeferrable) then continue; end if;
    if exists(select 1 from pg_constraint c where c.conrelid=v_table_oid and c.contype='p') then raise exception 'table pace_v2.% already has an incompatible primary key',v_pk.table_name; end if;
    execute format('alter table pace_v2.%I add constraint %I primary key(id)',v_pk.table_name,v_pk.constraint_name);
  end loop;

  for v_fk in
    select * from (values
      ('platform_quality_history','feedback_id','customer_feedback','platform_quality_history_feedback_fkey'),
      ('platform_quality_history','booking_id','bookings','platform_quality_history_booking_fkey'),
      ('captain_quality_history','feedback_id','customer_feedback','captain_quality_history_feedback_fkey'),
      ('captain_quality_history','booking_id','bookings','captain_quality_history_booking_fkey'),
      ('captain_quality_history','departure_id','departures','captain_quality_history_departure_fkey'),
      ('captain_quality_history','captain_id','captains','captain_quality_history_captain_fkey'),
      ('pickup_quality_history','feedback_id','customer_feedback','pickup_quality_history_feedback_fkey'),
      ('pickup_quality_history','booking_id','bookings','pickup_quality_history_booking_fkey'),
      ('pickup_quality_history','departure_id','departures','pickup_quality_history_departure_fkey'),
      ('pickup_quality_history','pickup_id','pickup_points','pickup_quality_history_pickup_fkey'),
      ('destination_quality_history','feedback_id','customer_feedback','destination_quality_history_feedback_fkey'),
      ('destination_quality_history','booking_id','bookings','destination_quality_history_booking_fkey'),
      ('destination_quality_history','departure_id','departures','destination_quality_history_departure_fkey'),
      ('destination_quality_history','destination_id','destinations','destination_quality_history_destination_fkey')
    ) as expected(table_name,column_name,target_table,constraint_name)
  loop
    v_table_oid:=to_regclass('pace_v2.'||v_fk.table_name);
    v_target_oid:=to_regclass('pace_v2.'||v_fk.target_table);
    select attnum into strict v_column_attnum from pg_attribute where attrelid=v_table_oid and attname=v_fk.column_name and not attisdropped;
    select attnum into strict v_target_attnum from pg_attribute where attrelid=v_target_oid and attname='id' and not attisdropped;
    select c.oid,c.contype,c.conkey,c.confrelid,c.confkey,c.confupdtype,c.confdeltype,c.confmatchtype,c.condeferrable into v_owned from pg_constraint c where c.conrelid=v_table_oid and c.conname=v_fk.constraint_name;
    if v_owned.oid is not null and not (
      v_owned.contype='f' and v_owned.conkey=array[v_column_attnum]::smallint[] and v_owned.confrelid=v_target_oid and v_owned.confkey=array[v_target_attnum]::smallint[]
      and v_owned.confupdtype='a' and v_owned.confdeltype='a' and v_owned.confmatchtype='s' and not v_owned.condeferrable
    ) then raise exception 'foreign key constraint % is owned with an incompatible definition',v_fk.constraint_name; end if;
    if v_owned.oid is null and not exists(
      select 1 from pg_constraint c where c.conrelid=v_table_oid and c.contype='f' and c.conkey=array[v_column_attnum]::smallint[]
        and c.confrelid=v_target_oid and c.confkey=array[v_target_attnum]::smallint[] and c.confupdtype='a' and c.confdeltype='a' and c.confmatchtype='s' and not c.condeferrable
    ) then
      execute format('alter table pace_v2.%I add constraint %I foreign key(%I) references pace_v2.%I(id) not valid',v_fk.table_name,v_fk.constraint_name,v_fk.column_name,v_fk.target_table);
    end if;
  end loop;

  for v_check in select * from (values
    ('platform_quality_history','platform_quality_history_row_check','feedback_id is not null and booking_id is not null and ((dimension=''booking_experience'' and rating between 1 and 5) or (dimension=''pace_shuttles_nps'' and rating between 0 and 10)) and rating_effect is not null and operator_score_effect=0 and occurred_at is not null'),
    ('captain_quality_history','captain_quality_history_row_check','feedback_id is not null and booking_id is not null and departure_id is not null and captain_id is not null and rating between 1 and 5 and rating_effect is not null and occurred_at is not null'),
    ('pickup_quality_history','pickup_quality_history_row_check','feedback_id is not null and booking_id is not null and departure_id is not null and pickup_id is not null and rating between 1 and 5 and rating_effect is not null and occurred_at is not null'),
    ('destination_quality_history','destination_quality_history_row_check','feedback_id is not null and booking_id is not null and departure_id is not null and destination_id is not null and rating between 1 and 5 and rating_effect is not null and occurred_at is not null')
  ) as expected(table_name,constraint_name,expression_sql)
  loop
    v_table_oid:=to_regclass('pace_v2.'||v_check.table_name); v_temp_name:=v_check.constraint_name||'_expected';
    execute format('alter table pace_v2.%I add constraint %I check(%s) not valid',v_check.table_name,v_temp_name,v_check.expression_sql);
    select conbin::text into v_expected_bin from pg_constraint where conrelid=v_table_oid and conname=v_temp_name;
    select c.oid,c.conbin,c.connoinherit into v_owned from pg_constraint c where c.conrelid=v_table_oid and c.conname=v_check.constraint_name;
    if v_owned.oid is not null and (v_owned.conbin::text is distinct from v_expected_bin or v_owned.connoinherit) then raise exception 'check constraint % is owned with an incompatible definition',v_check.constraint_name; end if;
    if v_owned.oid is not null or exists(select 1 from pg_constraint c where c.conrelid=v_table_oid and c.contype='c' and not c.connoinherit and c.conname<>v_temp_name and c.conbin::text=v_expected_bin) then
      execute format('alter table pace_v2.%I drop constraint %I',v_check.table_name,v_temp_name);
    else
      execute format('alter table pace_v2.%I rename constraint %I to %I',v_check.table_name,v_temp_name,v_check.constraint_name);
    end if;
  end loop;
end $$;

do $$
declare
  v_idx record; v_table_oid oid; v_owned_oid oid; v_columns_sql text;
begin
  for v_idx in select * from (values
    ('platform_quality_history','platform_quality_history_id_key',array['id']::text[],null::text,null::text,false),
    ('captain_quality_history','captain_quality_history_id_key',array['id']::text[],null::text,null::text,false),
    ('pickup_quality_history','pickup_quality_history_id_key',array['id']::text[],null::text,null::text,false),
    ('destination_quality_history','destination_quality_history_id_key',array['id']::text[],null::text,null::text,false),
    ('platform_quality_history','platform_quality_history_feedback_dimension_key',array['feedback_id','dimension']::text[],'feedback_id is not null and dimension is not null','((feedback_id IS NOT NULL) AND (dimension IS NOT NULL))',true),
    ('captain_quality_history','captain_quality_history_feedback_key',array['feedback_id']::text[],'feedback_id is not null','(feedback_id IS NOT NULL)',true),
    ('pickup_quality_history','pickup_quality_history_feedback_key',array['feedback_id']::text[],'feedback_id is not null','(feedback_id IS NOT NULL)',true),
    ('destination_quality_history','destination_quality_history_feedback_key',array['feedback_id']::text[],'feedback_id is not null','(feedback_id IS NOT NULL)',true)
  ) as expected(table_name,index_name,column_names,predicate_sql,expected_predicate,accept_nonpartial)
  loop
    v_table_oid:=to_regclass('pace_v2.'||v_idx.table_name);
    select string_agg(format('%I',column_name),',') into v_columns_sql from unnest(v_idx.column_names) as columns(column_name);
    v_owned_oid:=to_regclass('pace_v2.'||v_idx.index_name);
    if v_owned_oid is not null and not pace_v2._feedback_unique_index_matches(v_owned_oid,v_table_oid,v_idx.column_names,v_idx.expected_predicate,v_idx.accept_nonpartial) then raise exception 'unique index % is owned with an incompatible definition',v_idx.index_name; end if;
    if not exists(select 1 from pg_index candidate where pace_v2._feedback_unique_index_matches(candidate.indexrelid,v_table_oid,v_idx.column_names,v_idx.expected_predicate,v_idx.accept_nonpartial)) then
      execute format('create unique index %I on pace_v2.%I(%s)%s',v_idx.index_name,v_idx.table_name,v_columns_sql,case when v_idx.predicate_sql is null then '' else ' where '||v_idx.predicate_sql end);
    end if;
  end loop;
end $$;
create index if not exists captain_quality_history_captain_occurred_idx on pace_v2.captain_quality_history(captain_id,occurred_at);
create index if not exists pickup_quality_history_pickup_occurred_idx on pace_v2.pickup_quality_history(pickup_id,occurred_at);
create index if not exists destination_quality_history_destination_occurred_idx on pace_v2.destination_quality_history(destination_id,occurred_at);

alter table pace_v2.customer_feedback enable row level security;
alter table pace_v2.quality_configuration enable row level security;
alter table pace_v2.quality_evidence enable row level security;
alter table pace_v2.platform_quality_history enable row level security;
alter table pace_v2.captain_quality_history enable row level security;
alter table pace_v2.pickup_quality_history enable row level security;
alter table pace_v2.destination_quality_history enable row level security;
revoke all on pace_v2.customer_feedback,pace_v2.quality_configuration,pace_v2.quality_evidence,pace_v2.platform_quality_history,pace_v2.captain_quality_history,pace_v2.pickup_quality_history,pace_v2.destination_quality_history from public,anon,authenticated;

create or replace function pace_v2.feedback_due_at(p_actual_arrival_ts timestamptz,p_timezone text)
returns timestamptz language sql stable strict set search_path=pace_v2,public as $$
  select (((p_actual_arrival_ts at time zone p_timezone)::date+1+time '10:00') at time zone p_timezone);
$$;
revoke all on function pace_v2.feedback_due_at(timestamp with time zone,text) from public,anon,authenticated;

do $$
declare v_owned_oid oid:=to_regclass('pace_v2.customer_notifications_one_post_journey_feedback_per_booking');
begin
  if v_owned_oid is not null and not pace_v2._feedback_unique_index_matches(v_owned_oid,'pace_v2.notifications'::regclass,array['booking_id','template_code'],E'(template_code = \'post_journey_feedback\'::text)',true) then raise exception 'unique index % is owned with an incompatible definition','customer_notifications_one_post_journey_feedback_per_booking'; end if;
  if not exists(select 1 from pg_index candidate where pace_v2._feedback_unique_index_matches(candidate.indexrelid,'pace_v2.notifications'::regclass,array['booking_id','template_code'],E'(template_code = \'post_journey_feedback\'::text)',true)) then create unique index customer_notifications_one_post_journey_feedback_per_booking on pace_v2.notifications(booking_id,template_code) where template_code='post_journey_feedback'; end if;
end $$;

drop function pace_v2._feedback_unique_index_matches(oid,oid,text[],text,boolean,boolean,boolean);

create or replace function public.v2_system_schedule_feedback_requests(p_as_of timestamptz,p_limit integer default 100)
returns integer language plpgsql security definer set search_path=public,pace_v2,auth as $schedule$
declare v_row record; v_due_at timestamptz; v_queued integer:=0; v_feedback_url text;
begin
  if p_as_of is null then raise exception 'as-of timestamp required'; end if;
  update pace_v2.operational_alerts oa
  set resolved_at=now(),resolution_note='Country timezone corrected; feedback request will be queued when due'
  from pace_v2.confirmed_allocations ca
  join pace_v2.departures d on d.id=ca.departure_id
  join pace_v2.routes r on r.id=d.route_id
  join pace_v2.countries c on c.id=r.country_id
  join pg_timezone_names tz on tz.name=c.timezone
  where oa.exception_type='feedback_timezone_invalid' and oa.resolved_at is null and oa.confirmed_allocation_id=ca.id;
  insert into pace_v2.operational_alerts(exception_key,exception_type,severity,confirmed_allocation_id,booking_id,departure_id,details)
  select distinct on (b.id)
    'feedback_timezone_invalid:'||b.id::text,'feedback_timezone_invalid','high',ca.id,b.id,d.id,
    jsonb_build_object('country_name',c.name,'timezone',c.timezone,'as_of',p_as_of)
  from pace_v2.bookings b
  join pace_v2.booking_allocations ba on ba.booking_id=b.id
  join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status='confirmed'
  join pace_v2.departures d on d.id=ca.departure_id
  join pace_v2.routes r on r.id=d.route_id
  join pace_v2.countries c on c.id=r.country_id
  left join pg_timezone_names tz on tz.name=c.timezone
  join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id
  join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id)
  where tz.name is null and d.actual_arrival_ts is not null and d.actual_arrival_ts<=p_as_of
    and pace_v2.is_active_paid_journey_booking(b.id,null)
    and not exists(select 1 from pace_v2.customer_feedback cf where cf.booking_id=b.id)
    and pace_v2.is_valid_customer_notification_email(u.email)
    and nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),'') is not null
    and (select count(*) from pace_v2.captain_assignments a2 where a2.confirmed_allocation_id=ca.id and a2.active)=1
    and not exists(select 1 from pace_v2.notifications n where n.booking_id=b.id and n.template_code='post_journey_feedback')
  order by b.id,ca.id,a.id
  on conflict (exception_key) where resolved_at is null do update
    set severity='high',confirmed_allocation_id=excluded.confirmed_allocation_id,departure_id=excluded.departure_id,details=excluded.details,detected_at=excluded.detected_at;
  for v_row in
    select distinct on (b.id) b.id booking_id,ca.id confirmed_allocation_id,d.id departure_id,d.actual_arrival_ts,c.name country_name,c.timezone,
      pp.name pickup_name,dst.name destination_name,nullif(trim(u.email),'') to_email,
      split_part(nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),''),' ',1) first_name
    from pace_v2.bookings b
    join pace_v2.booking_allocations ba on ba.booking_id=b.id
    join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status='confirmed'
    join pace_v2.departures d on d.id=ca.departure_id
    join pace_v2.routes r on r.id=d.route_id
    join pace_v2.countries c on c.id=r.country_id
    join pg_timezone_names tz on tz.name=c.timezone
    join pace_v2.pickup_points pp on pp.id=r.pickup_id
    join pace_v2.destinations dst on dst.id=r.destination_id
    join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
    join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id
    join auth.users u on u.id=pace_v2.booking_owner_user_id(b.id)
    where d.actual_arrival_ts is not null and d.actual_arrival_ts<=p_as_of
      and case when tz.name is not null then pace_v2.feedback_due_at(d.actual_arrival_ts,c.timezone)<=p_as_of else false end
      and pace_v2.is_active_paid_journey_booking(b.id,null)
      and not exists(select 1 from pace_v2.customer_feedback cf where cf.booking_id=b.id)
      and not exists(select 1 from pace_v2.notifications n where n.booking_id=b.id and n.template_code='post_journey_feedback')
      and pace_v2.is_valid_customer_notification_email(u.email)
      and nullif(trim(coalesce(to_jsonb(b)->>'customer_name',to_jsonb(b)->>'lead_passenger_first_name',to_jsonb(b)->>'first_name','')),'') is not null
      and (select count(*) from pace_v2.captain_assignments a2 where a2.confirmed_allocation_id=ca.id and a2.active)=1
    order by b.id,ca.id,a.id
    limit least(greatest(coalesce(p_limit,0),0),500)
  loop
    v_due_at:=pace_v2.feedback_due_at(v_row.actual_arrival_ts,v_row.timezone);
    v_feedback_url:='https://www.paceshuttles.com/customer?booking='||v_row.booking_id::text||'&feedback=1';
    insert into pace_v2.notifications(booking_id,departure_id,to_email,template_code,subject,body,status,scheduled_at,metadata)
    values(v_row.booking_id,v_row.departure_id,v_row.to_email,'post_journey_feedback',
      'Thank you for travelling with Pace Shuttles – one more thing…',
      'Hi '||v_row.first_name||E',\n\nThank you for travelling with Pace Shuttles. We hope you had a wonderful journey in '||v_row.country_name||' from '||v_row.pickup_name||' to '||v_row.destination_name||E'.\n\nWould you mind telling us what went well and what we could improve? It should take no more than two minutes.\n\nShare your feedback\n'||v_feedback_url||E'\n\nRegards,\nThe Pace Shuttles Team',
      'queued',v_due_at,jsonb_build_object('feedback_url',v_feedback_url,'feedback_due_at',v_due_at,'country_name',v_row.country_name,'pickup_name',v_row.pickup_name,'destination_name',v_row.destination_name))
    on conflict (booking_id,template_code) where template_code='post_journey_feedback' do nothing;
    if found then v_queued:=v_queued+1; end if;
  end loop;
  return v_queued;
end;
$schedule$;

create or replace function public.v2_customer_submit_feedback(p_booking_id uuid,p_booking_experience_rating integer,p_nps integer,p_operator_rating integer,p_captain_rating integer,p_pickup_rating integer,p_destination_rating integer,p_went_well text,p_could_improve text,p_testimonial_consent boolean)
returns uuid language plpgsql security definer set search_path=public,pace_v2,auth as $submit$
declare
  v_user_id uuid:=auth.uid(); v_row record; v_feedback_id uuid; v_operator_weight numeric; v_captain_weight numeric; v_decay integer;
  operator_rating_effect numeric; captain_rating_effect numeric; weighted_rating numeric; v_low_dimensions jsonb:='[]'::jsonb;
begin
  if v_user_id is null then raise exception 'authentication required'; end if;
  if not pace_v2.is_active_paid_journey_booking(p_booking_id,v_user_id) then raise exception 'eligible paid booking owned by the authenticated customer required'; end if;
  if p_booking_experience_rating is null or p_nps is null or p_operator_rating is null or p_captain_rating is null or p_pickup_rating is null or p_destination_rating is null then raise exception 'all ratings are required'; end if;
  if p_booking_experience_rating not between 1 and 5 or p_operator_rating not between 1 and 5 or p_captain_rating not between 1 and 5 or p_pickup_rating not between 1 and 5 or p_destination_rating not between 1 and 5 then raise exception 'ratings must be integers from 1 to 5'; end if;
  if p_nps not between 0 and 10 then raise exception 'NPS must be an integer from 0 to 10'; end if;
  if p_testimonial_consent is null then raise exception 'testimonial consent must be explicit'; end if;
  select ca.id confirmed_allocation_id,ca.operator_id,ca.vehicle_id,d.id departure_id,d.actual_arrival_ts,r.pickup_id,r.destination_id,a.captain_id
  into strict v_row
  from pace_v2.bookings b
  join pace_v2.booking_allocations ba on ba.booking_id=b.id
  join pace_v2.confirmed_allocations ca on ca.consideration_id=ba.vehicle_consideration_id and ca.status='confirmed'
  join pace_v2.departures d on d.id=ca.departure_id
  join pace_v2.routes r on r.id=d.route_id
  join pace_v2.captain_assignments a on a.confirmed_allocation_id=ca.id and a.active
  join pace_v2.captains cap on cap.id=a.captain_id and cap.active and cap.operator_id=ca.operator_id
  where b.id=p_booking_id and d.actual_arrival_ts is not null and d.actual_arrival_ts<=now()
    and (select count(*) from pace_v2.captain_assignments a2 where a2.confirmed_allocation_id=ca.id and a2.active)=1;
  select operator_rating_weight,captain_rating_weight,evidence_decay_half_life_days into strict v_operator_weight,v_captain_weight,v_decay from pace_v2.quality_configuration where config_key='journey_feedback';
  operator_rating_effect:=(p_operator_rating-3)::numeric/2;
  captain_rating_effect:=(p_captain_rating-3)::numeric/2;
  weighted_rating := (operator_rating_effect * v_operator_weight) + (captain_rating_effect * v_captain_weight);

  insert into pace_v2.customer_feedback(booking_id,departure_id,confirmed_allocation_id,operator_id,vehicle_id,captain_id,pickup_id,destination_id,submitted_by,booking_experience_rating,pace_shuttles_nps_score,operator_rating,captain_rating,pickup_rating,destination_rating,went_well,could_improve,testimonial_consent,feedback_schema_version)
  values(p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,v_row.operator_id,v_row.vehicle_id,v_row.captain_id,v_row.pickup_id,v_row.destination_id,v_user_id,p_booking_experience_rating,p_nps,p_operator_rating,p_captain_rating,p_pickup_rating,p_destination_rating,nullif(trim(coalesce(p_went_well,'')),''),nullif(trim(coalesce(p_could_improve,'')),''),p_testimonial_consent,2)
  returning id into v_feedback_id;

  insert into pace_v2.platform_quality_history(feedback_id,booking_id,dimension,rating,rating_effect,operator_score_effect,occurred_at) values
    (v_feedback_id,p_booking_id,'booking_experience',p_booking_experience_rating,(p_booking_experience_rating-3)::numeric/2,0,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,'pace_shuttles_nps',p_nps,case when p_nps<=6 then -1 when p_nps<=8 then 0 else 1 end,0,v_row.actual_arrival_ts);
  insert into pace_v2.captain_quality_history(feedback_id,booking_id,departure_id,captain_id,rating,rating_effect,occurred_at) values(v_feedback_id,p_booking_id,v_row.departure_id,v_row.captain_id,p_captain_rating,captain_rating_effect,v_row.actual_arrival_ts);
  insert into pace_v2.pickup_quality_history(feedback_id,booking_id,departure_id,pickup_id,rating,rating_effect,occurred_at) values(v_feedback_id,p_booking_id,v_row.departure_id,v_row.pickup_id,p_pickup_rating,(p_pickup_rating-3)::numeric/2,v_row.actual_arrival_ts);
  insert into pace_v2.destination_quality_history(feedback_id,booking_id,departure_id,destination_id,rating,rating_effect,occurred_at) values(v_feedback_id,p_booking_id,v_row.departure_id,v_row.destination_id,p_destination_rating,(p_destination_rating-3)::numeric/2,v_row.actual_arrival_ts);

  insert into pace_v2.quality_evidence(feedback_id,booking_id,departure_id,confirmed_allocation_id,operator_id,vehicle_id,captain_id,pickup_id,destination_id,evidence_type,attribution,dimension,rating,rating_effect,operator_score_effect,evidence_weight,decay_half_life_days,occurred_at) values
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,null,null,null,null,null,'customer_feedback','pace_shuttles','booking_experience',p_booking_experience_rating,(p_booking_experience_rating-3)::numeric/2,0,1,v_decay,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,null,null,null,null,null,'customer_feedback','pace_shuttles','pace_shuttles_nps',p_nps,case when p_nps<=6 then -1 when p_nps<=8 then 0 else 1 end,0,1,v_decay,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,v_row.operator_id,v_row.vehicle_id,v_row.captain_id,null,null,'customer_feedback','operator','operator_journey',p_operator_rating,operator_rating_effect,weighted_rating,1,v_decay,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,v_row.operator_id,v_row.vehicle_id,v_row.captain_id,null,null,'customer_feedback','operator','captain',p_captain_rating,captain_rating_effect,0,1,v_decay,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,null,null,null,v_row.pickup_id,null,'customer_feedback','pace_shuttles','pickup',p_pickup_rating,(p_pickup_rating-3)::numeric/2,0,1,v_decay,v_row.actual_arrival_ts),
    (v_feedback_id,p_booking_id,v_row.departure_id,v_row.confirmed_allocation_id,null,null,null,null,v_row.destination_id,'customer_feedback','pace_shuttles','destination',p_destination_rating,(p_destination_rating-3)::numeric/2,0,1,v_decay,v_row.actual_arrival_ts);

  if p_booking_experience_rating<=2 then v_low_dimensions:=v_low_dimensions||'"booking_experience"'::jsonb; end if;
  if p_nps<=2 then v_low_dimensions:=v_low_dimensions||'"pace_shuttles_nps"'::jsonb; end if;
  if p_operator_rating<=2 then v_low_dimensions:=v_low_dimensions||'"operator_journey"'::jsonb; end if;
  if p_captain_rating<=2 then v_low_dimensions:=v_low_dimensions||'"captain"'::jsonb; end if;
  if p_pickup_rating<=2 then v_low_dimensions:=v_low_dimensions||'"pickup"'::jsonb; end if;
  if p_destination_rating<=2 then v_low_dimensions:=v_low_dimensions||'"destination"'::jsonb; end if;
  if jsonb_array_length(v_low_dimensions)>0 then
    insert into pace_v2.operational_alerts(exception_key,exception_type,severity,confirmed_allocation_id,booking_id,departure_id,details)
    values('journey_feedback_attribution_review:'||v_feedback_id::text,'journey_feedback_attribution_review','high',v_row.confirmed_allocation_id,p_booking_id,v_row.departure_id,jsonb_build_object('feedback_id',v_feedback_id,'low_dimensions',v_low_dimensions,'operator_score_effect',weighted_rating));
  end if;
  return v_feedback_id;
exception when no_data_found then raise exception 'completed confirmed journey with one captain required';
end;
$submit$;

revoke all on function public.v2_system_schedule_feedback_requests(timestamp with time zone,integer),public.v2_customer_submit_feedback(uuid,integer,integer,integer,integer,integer,integer,text,text,boolean) from public,anon,authenticated;
grant execute on function public.v2_system_schedule_feedback_requests(timestamp with time zone,integer) to service_role;
grant execute on function public.v2_customer_submit_feedback(uuid,integer,integer,integer,integer,integer,integer,text,text,boolean) to authenticated;

do $$
declare v_current oid:='public.v2_customer_submit_feedback(uuid,integer,integer,integer,integer,integer,integer,text,text,boolean)'::regprocedure; v_legacy regprocedure;
begin
  for v_legacy in select p.oid::regprocedure from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='v2_customer_submit_feedback' and p.oid<>v_current loop
    execute format('revoke all on function %s from public,anon,authenticated',v_legacy);
  end loop;
end $$;
