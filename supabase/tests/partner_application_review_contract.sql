begin;

do $$
begin
 if to_regclass('public.v2_admin_partner_applications') is null
 then raise exception 'Site Admin application view is missing'; end if;

 if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname in (
    'v2_admin_update_partner_application','v2_admin_set_partner_application_status','v2_admin_approve_partner_application'
   ))<>3 then raise exception 'Site Admin application RPCs are incomplete'; end if;

 if exists(select 1 from information_schema.routine_privileges
   where specific_schema='public' and routine_name in (
    'v2_admin_update_partner_application','v2_admin_set_partner_application_status','v2_admin_approve_partner_application'
   ) and grantee in ('PUBLIC','anon') and privilege_type='EXECUTE')
 then raise exception 'application review RPCs must not be public or anonymous'; end if;

 if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname in (
    'v2_admin_update_partner_application','v2_admin_set_partner_application_status','v2_admin_approve_partner_application'
   ) and pg_get_functiondef(p.oid) not ilike '%pace_v2.is_site_admin()%')
 then raise exception 'every application review RPC must enforce Site Admin access'; end if;

 if has_table_privilege('anon','public.v2_admin_partner_applications','select')
 then raise exception 'anonymous users must not read applications'; end if;

 if not has_table_privilege('authenticated','public.v2_admin_partner_applications','select')
 then raise exception 'authenticated Site Admin sessions require the applications view'; end if;

 if pg_get_viewdef('public.v2_admin_partner_applications'::regclass,true) not ilike '%is_site_admin%'
 then raise exception 'applications view must filter through Site Admin access'; end if;

 if pg_get_functiondef('public.v2_admin_approve_partner_application(uuid)'::regprocedure) not ilike '%for update%'
 then raise exception 'approval must lock the application row'; end if;
end
$$;

rollback;
