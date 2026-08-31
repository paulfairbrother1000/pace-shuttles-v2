begin;

do $$
begin
 if not exists(select 1 from information_schema.columns where table_schema='pace_v2' and table_name='destinations' and column_name='published_at')
 then raise exception 'destinations require published_at'; end if;
 if not exists(select 1 from information_schema.columns where table_schema='pace_v2' and table_name='destinations' and column_name='published_by')
 then raise exception 'destinations require published_by'; end if;
 if to_regprocedure('public.v2_admin_set_destination_published(uuid,boolean)') is null
 then raise exception 'destination publication RPC is missing'; end if;
 if has_function_privilege('anon','public.v2_admin_set_destination_published(uuid,boolean)','execute')
 then raise exception 'anonymous users must not publish destinations'; end if;
 if not has_function_privilege('authenticated','public.v2_admin_set_destination_published(uuid,boolean)','execute')
 then raise exception 'Site Admin sessions require the publication RPC'; end if;
 if pg_get_functiondef('public.v2_admin_set_destination_published(uuid,boolean)'::regprocedure) not ilike '%pace_v2.is_site_admin()%'
 then raise exception 'publication RPC must enforce Site Admin access'; end if;
 if pg_get_viewdef('public.v2_public_destinations'::regclass,true) not ilike '%published_at%'
 then raise exception 'public destinations must require publication'; end if;
 if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='v2_destinations' and column_name='published_at')
 then raise exception 'Site Admin destination view must expose publication state'; end if;
end
$$;

rollback;
