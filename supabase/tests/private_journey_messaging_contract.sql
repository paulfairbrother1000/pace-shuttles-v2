begin;

do $$
declare
  v_function regprocedure;
  v_view regclass;
begin
  foreach v_view in array array[
    'public.v2_customer_my_journey_conversations'::regclass,
    'public.v2_customer_my_journey_messages'::regclass,
    'public.v2_captain_my_journey_conversations'::regclass,
    'public.v2_captain_my_journey_messages'::regclass
  ] loop
    if v_view is null then raise exception 'private journey messaging view is missing'; end if;
    if has_table_privilege('anon',v_view,'select') then raise exception 'anonymous users must not read %',v_view; end if;
    if not has_table_privilege('authenticated',v_view,'select') then raise exception 'authenticated role needs filtered view %',v_view; end if;
    if not exists(select 1 from pg_class c where c.oid=v_view and c.reloptions @> array['security_invoker=true']) then raise exception '% must use security invoker',v_view; end if;
  end loop;

  foreach v_function in array array[
    'public.v2_customer_open_captain_conversation(uuid,text)'::regprocedure,
    'public.v2_customer_send_captain_message(uuid,text)'::regprocedure,
    'public.v2_captain_reply_to_party(uuid,text,text)'::regprocedure,
    'public.v2_site_admin_reply_journey_conversation(uuid,text,text)'::regprocedure
  ] loop
    if v_function is null then raise exception 'private journey messaging RPC is missing'; end if;
    if has_function_privilege('public',v_function,'execute') or has_function_privilege('anon',v_function,'execute') then raise exception 'private journey RPC % has public or anonymous execution',v_function; end if;
    if not has_function_privilege('authenticated',v_function,'execute') then raise exception 'authenticated role requires controlled execution of %',v_function; end if;
    if not exists(select 1 from pg_proc p where p.oid=v_function and p.prosecdef
      and p.proconfig @> array['search_path=public, pace_v2, auth']
      and pg_get_functiondef(p.oid) ilike '%auth.uid()%'
      and pg_get_functiondef(p.oid) ilike '%is_journey_message_window_open%') then
      raise exception 'private journey RPC % must be bounded and derive identity/window server-side',v_function;
    end if;
  end loop;

  if pg_get_viewdef('public.v2_customer_my_journey_conversations'::regclass,true) not ilike '%can_access_journey_conversation%' then raise exception 'customer conversation view must enforce booking ownership'; end if;
  if pg_get_viewdef('public.v2_captain_my_journey_conversations'::regclass,true) not ilike '%can_access_journey_conversation%' then raise exception 'captain conversation view must enforce assigned captain identity'; end if;
  if pg_get_viewdef('public.v2_captain_my_journey_messages'::regclass,true) not ilike '%can_access_journey_conversation%' then raise exception 'captain message view must enforce assigned captain identity'; end if;
  if pg_get_viewdef('public.v2_customer_my_journey_messages'::regclass,true) ilike '%email%' or pg_get_viewdef('public.v2_customer_my_journey_messages'::regclass,true) ilike '%phone%' then raise exception 'private customer messages must not expose contact details'; end if;
  if not exists(select 1 from pg_policy where polrelid='pace_v2.journey_conversations'::regclass and polname='journey_conversations_private_read' and polroles @> array['authenticated'::regrole::oid])
    or not exists(select 1 from pg_policy where polrelid='pace_v2.journey_conversation_messages'::regclass and polname='journey_messages_private_read' and polroles @> array['authenticated'::regrole::oid]) then raise exception 'journey tables require authenticated private read policies'; end if;
  if not has_column_privilege('authenticated','pace_v2.journey_conversations','confirmed_allocation_id','select') or not has_column_privilege('authenticated','pace_v2.journey_conversation_messages','conversation_id','select') then raise exception 'security-invoker views require read grants on RLS-protected base columns'; end if;
  if has_table_privilege('anon','pace_v2.journey_conversations','select') or has_table_privilege('anon','pace_v2.journey_conversation_messages','select') then raise exception 'anonymous users must not read journey base tables'; end if;
  if not has_column_privilege('authenticated','pace_v2.journey_conversation_messages','message_text','select') or has_column_privilege('authenticated','pace_v2.journey_conversation_messages','sender_user_id','select') then raise exception 'authenticated base message grants must expose view columns but never sender_user_id'; end if;
  if not has_function_privilege('authenticated','pace_v2.authorized_journey_message_window(uuid,text)','execute') or has_function_privilege('anon','pace_v2.authorized_journey_message_window(uuid,text)','execute') then raise exception 'only authenticated users may call the authorized conversation timing projection'; end if;
  if has_function_privilege('authenticated','pace_v2.journey_message_opens_at(uuid)','execute') or has_function_privilege('authenticated','pace_v2.journey_message_closes_at(uuid)','execute') or has_function_privilege('authenticated','pace_v2.is_journey_message_window_open(uuid,timestamp with time zone)','execute') then raise exception 'raw allocation timing helpers must remain unavailable to authenticated users'; end if;
  if pg_get_functiondef('pace_v2.authorized_journey_message_window(uuid,text)'::regprocedure) not ilike '%can_access_journey_conversation%' then raise exception 'timing projection must validate conversation authorization'; end if;
end $$;

rollback;
