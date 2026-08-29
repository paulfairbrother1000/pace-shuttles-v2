begin;

do $$
begin
 if to_regclass('pace_v2.partner_applications') is null
 then raise exception 'partner applications table is missing'; end if;

 if to_regclass('pace_v2.partner_application_places') is null
 then raise exception 'partner application places table is missing'; end if;

 if (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
     where n.nspname='pace_v2' and c.relname in ('partner_applications','partner_application_places') and c.relrowsecurity)<>2
 then raise exception 'partner application tables must have RLS enabled'; end if;

 if (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
     where n.nspname='public' and c.relname in (
       'v2_public_partner_form_countries','v2_public_partner_form_transport_types',
       'v2_public_partner_form_destination_types','v2_public_partner_form_places'
     ) and c.relkind='v')<>4
 then raise exception 'public partner form lookup views are incomplete'; end if;

 if exists(select 1 from information_schema.role_table_grants
   where table_schema='pace_v2' and table_name in ('partner_applications','partner_application_places')
   and grantee in ('PUBLIC','anon','authenticated'))
 then raise exception 'application tables must not be granted to API roles'; end if;

 if not has_function_privilege('anon','public.v2_public_submit_partner_application(jsonb)','EXECUTE')
 then raise exception 'anonymous applicants require the submission RPC'; end if;

 if not has_function_privilege('authenticated','public.v2_public_submit_partner_application(jsonb)','EXECUTE')
 then raise exception 'signed-in applicants require the submission RPC'; end if;

 if has_function_privilege('public','public.v2_public_submit_partner_application(jsonb)','EXECUTE')
 then raise exception 'submission RPC must revoke the PostgreSQL PUBLIC default'; end if;

 if not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='v2_public_submit_partner_application'
   and p.prosecdef and p.proconfig @> array['search_path=""'])
 then raise exception 'submission RPC must be a bounded security definer with an empty search path'; end if;
end
$$;

rollback;
