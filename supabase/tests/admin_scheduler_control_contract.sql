begin;
do $$ begin
 if has_function_privilege('anon','public.v2_site_admin_scheduler_dashboard()','execute') then raise exception 'anon scheduler dashboard access exists'; end if;
 if has_function_privilege('anon','public.v2_site_admin_set_scheduler_enabled(boolean,text)','execute') then raise exception 'anon scheduler mutation access exists'; end if;
 if not has_function_privilege('authenticated','public.v2_site_admin_scheduler_dashboard()','execute') then raise exception 'authenticated dashboard grant missing'; end if;
 if not has_function_privilege('service_role','public.v2_system_scheduler_begin(text,timestamp with time zone)','execute') then raise exception 'service scheduler grant missing'; end if;
 if has_table_privilege('authenticated','pace_v2.scheduler_audit','insert') then raise exception 'audit table is directly mutable'; end if;
end $$;
rollback;

