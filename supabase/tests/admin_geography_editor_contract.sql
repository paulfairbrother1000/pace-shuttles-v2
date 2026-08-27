begin;

do $$
begin
 if not exists(select 1 from information_schema.columns where table_schema='pace_v2' and table_name='destinations' and column_name='directions_url')
 then raise exception 'destinations require a Google Maps directions URL'; end if;

 if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname in ('v2_admin_save_country','v2_admin_save_pickup','v2_admin_save_destination'))<>3
 then raise exception 'protected geography save RPCs are incomplete'; end if;

 if exists(select 1 from information_schema.routine_privileges where specific_schema='public'
   and routine_name in ('v2_admin_save_country','v2_admin_save_pickup','v2_admin_save_destination')
   and grantee in ('PUBLIC','anon') and privilege_type='EXECUTE')
 then raise exception 'geography save RPCs must not be public or anonymous'; end if;

 if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname in ('v2_admin_save_country','v2_admin_save_pickup','v2_admin_save_destination')
   and pg_get_functiondef(p.oid) not ilike '%pace_v2.is_site_admin()%')
 then raise exception 'every geography save RPC must enforce Site Admin access'; end if;

 if not exists(select 1 from storage.buckets where id='images' and public and file_size_limit=8388608)
 then raise exception 'the existing images contract requires a public 8 MB images bucket'; end if;

 if (select count(*) from pg_policy where polrelid='storage.objects'::regclass
   and polname in ('Site Admin uploads geography images','Site Admin reads geography image objects','Site Admin replaces geography images'))<>3
 then raise exception 'Site Admin geography upload policies are incomplete'; end if;

 if not exists(select 1 from pg_policy where polrelid='pace_v2.destinations'::regclass
   and polname='destinations_admin_read' and pg_get_expr(polqual,polrelid) ilike '%is_site_admin%')
 then raise exception 'Site Admin destination reads require an RLS policy'; end if;

 if not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relname='v2_destinations' and c.reloptions @> array['security_invoker=true'])
 then raise exception 'the admin destinations view must invoke underlying RLS'; end if;
end
$$;

rollback;
