begin;
do $$ begin
 if not exists(select 1 from information_schema.columns where table_schema='pace_v2' and table_name='countries' and column_name='customer_availability_paused') then raise exception 'country pause column missing';end if;
 if not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='v2_admin_set_country_customer_availability' and pg_get_functiondef(p.oid) ilike '%pace_v2.is_site_admin()%') then raise exception 'protected admin pause RPC missing';end if;
 if exists(select 1 from information_schema.routine_privileges where specific_schema='public' and routine_name='v2_admin_set_country_customer_availability' and grantee in('PUBLIC','anon')) then raise exception 'pause RPC exposed publicly';end if;
 if pg_get_viewdef('public.v2_public_departures'::regclass,true) not ilike '%customer_availability_paused is not true%' then raise exception 'public departures do not enforce country pause';end if;
 if pg_get_functiondef('public.v2_public_quote(uuid,integer)'::regprocedure) not ilike '%customer_availability_paused is not true%' then raise exception 'quote does not enforce country pause';end if;
end $$;
rollback;
