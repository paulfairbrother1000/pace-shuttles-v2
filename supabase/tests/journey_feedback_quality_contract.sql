begin;

-- Test the same catalog-only semantics as the migration without building
-- template indexes on the tables under test.
create or replace function pace_v2._feedback_contract_unique_index_matches(
  p_index_oid oid,p_table_oid oid,p_column_names text[],p_expected_predicate text default null,
  p_accept_nonpartial boolean default false,p_nulls_not_distinct boolean default false,p_immediate boolean default true
) returns boolean language plpgsql stable set search_path=pg_catalog as $index_shape$
declare
  v_btree_method oid; v_expected_count integer; v_expected_keys smallint[];
  v_expected_opclasses oid[]; v_expected_collations oid[]; v_expected_options smallint[];
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
    select opclass.oid from pg_opclass opclass
    where opclass.opcmethod=v_btree_method and opclass.opcdefault
      and (opclass.opcintype=attribute.atttypid or exists(select 1 from pg_cast cast_entry where cast_entry.castsource=attribute.atttypid and cast_entry.casttarget=opclass.opcintype and cast_entry.castmethod='b' and cast_entry.castcontext in('i','a')))
    order by (opclass.opcintype=attribute.atttypid) desc,opclass.oid limit 1
  ) default_opclass on true;
  if v_expected_count<>cardinality(p_column_names) then raise exception 'cannot derive contract btree shape for %.%',p_table_oid::regclass,p_column_names; end if;
  return exists(
    select 1 from pg_index candidate join pg_class index_class on index_class.oid=candidate.indexrelid
    where candidate.indexrelid=p_index_oid and candidate.indrelid=p_table_oid and index_class.relam=v_btree_method
      and candidate.indisunique and candidate.indisvalid and candidate.indisready and candidate.indislive
      and candidate.indimmediate=p_immediate and not candidate.indisexclusion and candidate.indnullsnotdistinct=p_nulls_not_distinct
      and candidate.indexprs is null and candidate.indnkeyatts=v_expected_count and candidate.indnatts=v_expected_count
      and (select array_agg(entry.value order by entry.position) from unnest(candidate.indkey::smallint[]) with ordinality entry(value,position))=v_expected_keys
      and (select array_agg(entry.value order by entry.position) from unnest(candidate.indclass::oid[]) with ordinality entry(value,position))=v_expected_opclasses
      and (select array_agg(entry.value order by entry.position) from unnest(candidate.indcollation::oid[]) with ordinality entry(value,position))=v_expected_collations
      and (select array_agg(entry.value order by entry.position) from unnest(candidate.indoption::smallint[]) with ordinality entry(value,position))=v_expected_options
      and ((p_expected_predicate is null and candidate.indpred is null) or (p_expected_predicate is not null and (pg_get_expr(candidate.indpred,candidate.indrelid,false)=p_expected_predicate or (p_accept_nonpartial and candidate.indpred is null))))
  );
end
$index_shape$;

create temporary table feedback_index_guard_probe(a text,b text);
create unique index feedback_index_guard_probe_wrong_opclass on feedback_index_guard_probe(a text_pattern_ops);
create unique index feedback_index_guard_probe_wrong_collation on feedback_index_guard_probe(a collate "C");
create unique index feedback_index_guard_probe_wrong_options on feedback_index_guard_probe(a desc nulls first);
create unique index feedback_index_guard_probe_wrong_nulls on feedback_index_guard_probe(a) nulls not distinct;
create unique index feedback_index_guard_probe_wrong_predicate on feedback_index_guard_probe(a) where b is not null;
alter table feedback_index_guard_probe add constraint feedback_index_guard_probe_deferred unique(a) deferrable initially deferred;
create unique index feedback_index_guard_probe_stronger on feedback_index_guard_probe(a,b);
do $$
begin
  if pace_v2._feedback_contract_unique_index_matches(to_regclass('pg_temp.feedback_index_guard_probe_wrong_opclass'),'pg_temp.feedback_index_guard_probe'::regclass,array['a']) then raise exception 'wrong operator class passed exact-index guard'; end if;
  if pace_v2._feedback_contract_unique_index_matches(to_regclass('pg_temp.feedback_index_guard_probe_wrong_collation'),'pg_temp.feedback_index_guard_probe'::regclass,array['a']) then raise exception 'wrong collation passed exact-index guard'; end if;
  if pace_v2._feedback_contract_unique_index_matches(to_regclass('pg_temp.feedback_index_guard_probe_wrong_options'),'pg_temp.feedback_index_guard_probe'::regclass,array['a']) then raise exception 'wrong index options passed exact-index guard'; end if;
  if pace_v2._feedback_contract_unique_index_matches(to_regclass('pg_temp.feedback_index_guard_probe_wrong_nulls'),'pg_temp.feedback_index_guard_probe'::regclass,array['a']) then raise exception 'wrong null semantics passed exact-index guard'; end if;
  if pace_v2._feedback_contract_unique_index_matches(to_regclass('pg_temp.feedback_index_guard_probe_deferred'),'pg_temp.feedback_index_guard_probe'::regclass,array['a']) then raise exception 'deferred unique constraint passed immediate-index guard'; end if;
  if pace_v2._feedback_contract_unique_index_matches(to_regclass('pg_temp.feedback_index_guard_probe_wrong_predicate'),'pg_temp.feedback_index_guard_probe'::regclass,array['a'],'(a IS NOT NULL)') then raise exception 'wrong partial predicate passed exact-index guard'; end if;
  if not pace_v2._feedback_contract_unique_index_matches(to_regclass('pg_temp.feedback_index_guard_probe_stronger'),'pg_temp.feedback_index_guard_probe'::regclass,array['a','b'],'(a IS NOT NULL)',true) then raise exception 'stronger nonpartial unique index was not accepted'; end if;
end $$;

do $$
declare
  v_table text;
  v_column text;
  v_submit regprocedure:='public.v2_customer_submit_feedback(uuid,integer,integer,integer,integer,integer,integer,text,text,boolean)'::regprocedure;
  v_scheduler regprocedure:='public.v2_system_schedule_feedback_requests(timestamp with time zone,integer)'::regprocedure;
begin
  foreach v_table in array array[
    'customer_feedback','platform_quality_history','captain_quality_history',
    'pickup_quality_history','destination_quality_history','quality_evidence','quality_configuration'
  ] loop
    if to_regclass('pace_v2.'||v_table) is null then raise exception '% missing',v_table; end if;
    if not (select relrowsecurity from pg_class where oid=('pace_v2.'||v_table)::regclass) then
      raise exception '% is not protected by RLS',v_table;
    end if;
    if has_table_privilege('anon','pace_v2.'||v_table,'select,insert,update,delete')
      or has_table_privilege('authenticated','pace_v2.'||v_table,'insert,update,delete') then
      raise exception '% exposes direct writes',v_table;
    end if;
  end loop;

  foreach v_column in array array[
    'booking_experience_rating','pace_shuttles_nps_score','operator_rating','captain_rating',
    'pickup_rating','destination_rating','went_well','could_improve','testimonial_consent',
    'operator_id','vehicle_id','captain_id','pickup_id','destination_id','confirmed_allocation_id','departure_id'
  ] loop
    if not exists(select 1 from information_schema.columns where table_schema='pace_v2' and table_name='customer_feedback' and column_name=v_column) then
      raise exception 'customer_feedback.% missing',v_column;
    end if;
  end loop;

  if not exists(select 1 from pg_index i where pace_v2._feedback_contract_unique_index_matches(i.indexrelid,'pace_v2.customer_feedback'::regclass,array['booking_id'])) then
    raise exception 'one feedback response per booking is not enforced';
  end if;
  if not exists(select 1 from pg_attrdef d join pg_attribute a on a.attrelid=d.adrelid and a.attnum=d.adnum where d.adrelid='pace_v2.customer_feedback'::regclass and a.attname='testimonial_consent' and pg_get_expr(d.adbin,d.adrelid)='false') then
    raise exception 'testimonial consent must default false';
  end if;
  if v_submit is null or v_scheduler is null then raise exception 'feedback RPC contract missing'; end if;
  if has_function_privilege('anon',v_submit,'execute') or not has_function_privilege('authenticated',v_submit,'execute') then
    raise exception 'feedback submission grants are unsafe';
  end if;
  if has_function_privilege('anon',v_scheduler,'execute') or has_function_privilege('authenticated',v_scheduler,'execute') or not has_function_privilege('service_role',v_scheduler,'execute') then
    raise exception 'feedback scheduler grants are unsafe';
  end if;
  if exists(select 1 from pg_proc where oid=v_submit and pg_get_function_arguments(oid) ~* 'p_(operator_id|vehicle_id|captain_id|pickup_id|destination_id|attribution)') then
    raise exception 'feedback client can submit attribution targets';
  end if;
  if not exists(select 1 from pg_constraint where conrelid='pace_v2.customer_feedback'::regclass and pg_get_constraintdef(oid) ilike '%feedback_schema_version%' and pg_get_constraintdef(oid) ilike '%booking_experience_rating is not null%' and pg_get_constraintdef(oid) ilike '%pace_shuttles_nps_score is not null%') then
    raise exception 'new feedback rows do not require every rating';
  end if;
  if exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='v2_customer_submit_feedback' and p.oid<>v_submit and (has_function_privilege('anon',p.oid,'execute') or has_function_privilege('authenticated',p.oid,'execute'))) then
    raise exception 'legacy customer-submitted attribution overload remains executable';
  end if;
end $$;

do $$
begin
  if not exists(select 1 from pace_v2.quality_configuration where config_key='journey_feedback' and operator_rating_weight=0.60 and captain_rating_weight=0.40 and operator_rating_weight+captain_rating_weight=1) then
    raise exception 'configurable initial operator/captain weights missing';
  end if;
  if not exists(select 1 from pg_index i where pace_v2._feedback_contract_unique_index_matches(i.indexrelid,'pace_v2.notifications'::regclass,array['booking_id','template_code'],E'(template_code = \'post_journey_feedback\'::text)',true)) then
    raise exception 'feedback notification de-duplication missing';
  end if;
end $$;

do $$
declare
  v_table text; v_column text; v_columns text[]; v_fk record; v_check record; v_table_oid oid; v_target_oid oid;
  v_attnum smallint; v_target_attnum smallint; v_expected_predicate text; v_expected_check text; v_check_sql text; v_temp_check text;
begin
  foreach v_table in array array['platform_quality_history','captain_quality_history','pickup_quality_history','destination_quality_history'] loop
    v_columns:=case v_table
      when 'platform_quality_history' then array['id','feedback_id','booking_id','dimension','rating','rating_effect','operator_score_effect','occurred_at','created_at']
      when 'captain_quality_history' then array['id','feedback_id','booking_id','departure_id','captain_id','rating','rating_effect','occurred_at','created_at']
      when 'pickup_quality_history' then array['id','feedback_id','booking_id','departure_id','pickup_id','rating','rating_effect','occurred_at','created_at']
      else array['id','feedback_id','booking_id','departure_id','destination_id','rating','rating_effect','occurred_at','created_at'] end;
    foreach v_column in array v_columns loop
      if not exists(select 1 from information_schema.columns where table_schema='pace_v2' and table_name=v_table and column_name=v_column) then raise exception '%.% missing after additive upgrade',v_table,v_column; end if;
    end loop;
    if not exists(select 1 from pg_constraint where conrelid=('pace_v2.'||v_table)::regclass and contype='p') then raise exception '%.id primary key missing',v_table; end if;
    v_check_sql:=case v_table
      when 'platform_quality_history' then 'feedback_id is not null and booking_id is not null and ((dimension=''booking_experience'' and rating between 1 and 5) or (dimension=''pace_shuttles_nps'' and rating between 0 and 10)) and rating_effect is not null and operator_score_effect=0 and occurred_at is not null'
      when 'captain_quality_history' then 'feedback_id is not null and booking_id is not null and departure_id is not null and captain_id is not null and rating between 1 and 5 and rating_effect is not null and occurred_at is not null'
      when 'pickup_quality_history' then 'feedback_id is not null and booking_id is not null and departure_id is not null and pickup_id is not null and rating between 1 and 5 and rating_effect is not null and occurred_at is not null'
      else 'feedback_id is not null and booking_id is not null and departure_id is not null and destination_id is not null and rating between 1 and 5 and rating_effect is not null and occurred_at is not null' end;
    v_temp_check:='contract_expected_'||v_table||'_row';
    execute format('alter table pace_v2.%I add constraint %I check(%s) not valid',v_table,v_temp_check,v_check_sql);
    select pg_get_expr(c.conbin,c.conrelid,false) into strict v_expected_check from pg_constraint c where c.conrelid=('pace_v2.'||v_table)::regclass and c.conname=v_temp_check;
    execute format('alter table pace_v2.%I drop constraint %I',v_table,v_temp_check);
    if not exists(select 1 from pg_constraint c where c.conrelid=('pace_v2.'||v_table)::regclass and c.contype='c' and not c.connoinherit and pg_get_expr(c.conbin,c.conrelid,false)=v_expected_check) then raise exception '%.equivalent row check missing',v_table; end if;
    if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name=v_table and column_name='id')<>'uuid' then raise exception '%.id is not uuid',v_table; end if;
    if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name=v_table and column_name='rating') not in('smallint','integer','bigint','numeric') then raise exception '%.rating is not numeric-compatible',v_table; end if;
    if (select data_type from information_schema.columns where table_schema='pace_v2' and table_name=v_table and column_name='occurred_at')<>'timestamp with time zone' then raise exception '%.occurred_at is not timestamptz',v_table; end if;
    if (select is_nullable from information_schema.columns where table_schema='pace_v2' and table_name=v_table and column_name='id')<>'NO' then raise exception '%.id remains nullable',v_table; end if;
    if (select is_nullable from information_schema.columns where table_schema='pace_v2' and table_name=v_table and column_name='created_at')<>'NO' then raise exception '%.created_at remains nullable',v_table; end if;
    if not exists(select 1 from pg_index i where pace_v2._feedback_contract_unique_index_matches(i.indexrelid,('pace_v2.'||v_table)::regclass,array['id'])) then raise exception '%.id uniqueness missing',v_table; end if;
    v_columns:=case when v_table='platform_quality_history' then array['feedback_id','dimension'] else array['feedback_id'] end;
    v_expected_predicate:=case when v_table='platform_quality_history' then '((feedback_id IS NOT NULL) AND (dimension IS NOT NULL))' else '(feedback_id IS NOT NULL)' end;
    if not exists(select 1 from pg_index i where pace_v2._feedback_contract_unique_index_matches(i.indexrelid,('pace_v2.'||v_table)::regclass,v_columns,v_expected_predicate,true)) then raise exception '%.feedback uniqueness missing',v_table; end if;
  end loop;
  for v_fk in
    select * from (values
      ('platform_quality_history','feedback_id','customer_feedback'),('platform_quality_history','booking_id','bookings'),
      ('captain_quality_history','feedback_id','customer_feedback'),('captain_quality_history','booking_id','bookings'),('captain_quality_history','departure_id','departures'),('captain_quality_history','captain_id','captains'),
      ('pickup_quality_history','feedback_id','customer_feedback'),('pickup_quality_history','booking_id','bookings'),('pickup_quality_history','departure_id','departures'),('pickup_quality_history','pickup_id','pickup_points'),
      ('destination_quality_history','feedback_id','customer_feedback'),('destination_quality_history','booking_id','bookings'),('destination_quality_history','departure_id','departures'),('destination_quality_history','destination_id','destinations')
    ) as expected(table_name,column_name,target_table)
  loop
    v_table_oid:=to_regclass('pace_v2.'||v_fk.table_name); v_target_oid:=to_regclass('pace_v2.'||v_fk.target_table);
    select attnum into strict v_attnum from pg_attribute where attrelid=v_table_oid and attname=v_fk.column_name and not attisdropped;
    select attnum into strict v_target_attnum from pg_attribute where attrelid=v_target_oid and attname='id' and not attisdropped;
    if not exists(select 1 from pg_constraint where conrelid=v_table_oid and contype='f' and conkey=array[v_attnum]::smallint[] and confrelid=v_target_oid and confkey=array[v_target_attnum]::smallint[] and confupdtype='a' and confdeltype='a' and confmatchtype='s' and not condeferrable) then raise exception '%.% exact foreign key to %.id missing',v_fk.table_name,v_fk.column_name,v_fk.target_table; end if;
  end loop;
  if (select is_nullable from information_schema.columns where table_schema='pace_v2' and table_name='customer_feedback' and column_name='testimonial_consent')<>'NO'
    or (select column_default from information_schema.columns where table_schema='pace_v2' and table_name='customer_feedback' and column_name='testimonial_consent') not ilike '%false%' then raise exception 'testimonial consent existing-column invariant missing'; end if;
  if (select is_nullable from information_schema.columns where table_schema='pace_v2' and table_name='customer_feedback' and column_name='feedback_schema_version')<>'NO'
    or (select column_default from information_schema.columns where table_schema='pace_v2' and table_name='customer_feedback' and column_name='feedback_schema_version') not like '%2%' then raise exception 'feedback schema version existing-column invariant missing'; end if;
  if exists(select 1 from pace_v2.customer_feedback where testimonial_consent is null or feedback_schema_version is null) then raise exception 'existing feedback null invariant was not repaired'; end if;
  for v_check in select * from (values
    ('booking_experience','feedback_schema_version<2 or (booking_experience_rating between 1 and 5 and booking_experience_rating::numeric=trunc(booking_experience_rating::numeric))'),
    ('operator','feedback_schema_version<2 or (operator_rating between 1 and 5 and operator_rating::numeric=trunc(operator_rating::numeric))'),
    ('captain','feedback_schema_version<2 or (captain_rating between 1 and 5 and captain_rating::numeric=trunc(captain_rating::numeric))'),
    ('pickup','feedback_schema_version<2 or (pickup_rating between 1 and 5 and pickup_rating::numeric=trunc(pickup_rating::numeric))'),
    ('destination','feedback_schema_version<2 or (destination_rating between 1 and 5 and destination_rating::numeric=trunc(destination_rating::numeric))'),
    ('nps','feedback_schema_version<2 or (pace_shuttles_nps_score between 0 and 10 and pace_shuttles_nps_score::numeric=trunc(pace_shuttles_nps_score::numeric))'),
    ('required','feedback_schema_version<2 or (booking_experience_rating is not null and pace_shuttles_nps_score is not null and operator_rating is not null and captain_rating is not null and pickup_rating is not null and destination_rating is not null)')
  ) as expected(check_label,expression_sql)
  loop
    v_temp_check:='contract_expected_feedback_'||v_check.check_label;
    execute format('alter table pace_v2.customer_feedback add constraint %I check(%s) not valid',v_temp_check,v_check.expression_sql);
    select pg_get_expr(c.conbin,c.conrelid,false) into strict v_expected_check from pg_constraint c where c.conrelid='pace_v2.customer_feedback'::regclass and c.conname=v_temp_check;
    execute format('alter table pace_v2.customer_feedback drop constraint %I',v_temp_check);
    if not exists(select 1 from pg_constraint c where c.conrelid='pace_v2.customer_feedback'::regclass and c.contype='c' and not c.connoinherit and pg_get_expr(c.conbin,c.conrelid,false)=v_expected_check) then raise exception 'new-schema equivalent % check missing',v_check.check_label; end if;
  end loop;
end $$;

rollback;
