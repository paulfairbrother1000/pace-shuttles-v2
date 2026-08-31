begin;

do $$
declare v_view text; v_expected text[]; v_actual text[];
begin
 for v_view,v_expected in select * from (values
  ('v2_admin_operational_alerts',array['id','exception_key','exception_type','severity','confirmed_allocation_id','booking_id','departure_id','route_name','details','detected_at','resolved_at','resolution_note','created_at']),
  ('v2_admin_journey_conversations',array['conversation_id','booking_id','confirmed_allocation_id','status','opened_at','closed_at','created_at','route_name','customer_name','inbound_message_count']),
  ('v2_admin_journey_messages',array['id','conversation_id','sender_type','category','message_text','broadcast_source_id','created_at']),
  ('v2_admin_journey_broadcast_deliveries',array['id','broadcast_message_id','booking_id','conversation_id','delivered_at','in_app_read_at','email_status','email_provider_id','email_failed_at','email_failure_reason','created_at','route_name'])
 ) expected(view_name,column_names)
 loop
  select array_agg(column_name order by ordinal_position) into v_actual from information_schema.columns where table_schema='public' and table_name=v_view;
  if v_actual is distinct from v_expected then raise exception '%. columns mismatch: %',v_view,v_actual; end if;
 end loop;
 if has_table_privilege('anon','public.v2_admin_operational_alerts','select')
  or has_table_privilege('anon','public.v2_admin_journey_conversations','select')
  or has_table_privilege('anon','public.v2_admin_journey_messages','select')
  or has_table_privilege('anon','public.v2_admin_journey_broadcast_deliveries','select')
  or has_function_privilege('anon','public.v2_site_admin_quality_dashboard()','execute')
  or has_function_privilege('anon','public.v2_site_admin_quality_evidence_page(integer,integer)','execute')
  or has_function_privilege('public','public.v2_site_admin_quality_dashboard()','execute')
  or has_function_privilege('public','public.v2_site_admin_quality_evidence_page(integer,integer)','execute') then
  raise exception 'anonymous/default Site Admin reporting privilege exists';
 end if;
 if not has_table_privilege('authenticated','public.v2_admin_operational_alerts','select')
  or not has_table_privilege('authenticated','public.v2_admin_journey_conversations','select')
  or not has_table_privilege('authenticated','public.v2_admin_journey_messages','select')
  or not has_table_privilege('authenticated','public.v2_admin_journey_broadcast_deliveries','select')
  or not has_function_privilege('authenticated','public.v2_site_admin_quality_dashboard()','execute')
  or not has_function_privilege('authenticated','public.v2_site_admin_quality_evidence_page(integer,integer)','execute') then
  raise exception 'authenticated reporting grants are missing';
 end if;
end $$;

rollback;
