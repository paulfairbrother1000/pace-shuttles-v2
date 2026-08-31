begin;
do $$
begin
 if to_regclass('pace_v2.journey_message_read_states') is null then raise exception 'journey message read state table missing'; end if;
 if to_regprocedure('public.v2_mark_journey_conversation_read(uuid,text)') is null then raise exception 'protected mark-read RPC missing'; end if;
 if to_regprocedure('public.v2_customer_my_journey_message_windows()') is null then raise exception 'customer booking window RPC missing'; end if;
 if to_regclass('public.v2_customer_my_journey_message_windows') is not null then raise exception 'superseded customer booking window view remains'; end if;
 if to_regclass('public.v2_captain_my_journey_message_windows') is null then raise exception 'captain allocation window projection missing'; end if;
 if has_table_privilege('anon','pace_v2.journey_message_read_states','select') or has_table_privilege('authenticated','pace_v2.journey_message_read_states','select') then raise exception 'read markers must remain behind protected views/RPCs'; end if;
 if not has_function_privilege('authenticated','public.v2_mark_journey_conversation_read(uuid,text)','execute') or has_function_privilege('anon','public.v2_mark_journey_conversation_read(uuid,text)','execute') then raise exception 'mark-read RPC grants are incorrect'; end if;
 if not has_function_privilege('authenticated','public.v2_customer_my_journey_message_windows()','execute') or has_function_privilege('anon','public.v2_customer_my_journey_message_windows()','execute') then raise exception 'customer booking window RPC grants are incorrect'; end if;
 if has_function_privilege('authenticated','pace_v2.authorized_customer_booking_message_window(uuid)','execute') or has_function_privilege('anon','pace_v2.authorized_customer_booking_message_window(uuid)','execute') then raise exception 'keyed customer window helper must not be callable by API roles'; end if;
 if pg_get_functiondef('public.v2_customer_my_journey_message_windows()'::regprocedure) not ilike '%authorized_customer_booking_message_window%' then raise exception 'customer window RPC must retain owner-internal helper usage'; end if;
 if not has_function_privilege('authenticated','pace_v2.authorized_journey_conversation_unread_count(uuid,text)','execute') or has_function_privilege('anon','pace_v2.authorized_journey_conversation_unread_count(uuid,text)','execute') then raise exception 'unread projection helper grants are incorrect'; end if;
 if pg_get_viewdef('public.v2_captain_my_journey_message_windows'::regclass,true) not ilike '%authorized_captain_allocation_message_window%' then raise exception 'captain allocation projection must use authorized server window helper'; end if;
 if pg_get_viewdef('public.v2_captain_my_journey_conversations'::regclass,true) not ilike '%unread_count%' then raise exception 'captain conversations must project unread count'; end if;
end $$;
rollback;
