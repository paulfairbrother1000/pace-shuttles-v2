-- Preserve predecessor Finance projections while making the dedicated Site Admin evidence feed safely pageable.

alter view public.v2_admin_journey_conversations rename column unread_count to inbound_message_count;

create or replace function public.v2_site_admin_quality_evidence_page(p_offset integer,p_limit integer)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $evidence$
declare
 v_items jsonb;
 v_total bigint;
 v_offset integer:=greatest(coalesce(p_offset,0),0);
 v_limit integer:=least(greatest(coalesce(p_limit,25),1),100);
begin
 if not pace_v2.is_site_admin() then raise exception 'site admin required'; end if;

 select count(*) into v_total from pace_v2.customer_feedback;
 select coalesce(jsonb_agg(to_jsonb(page_row) order by page_row.created_at desc,page_row.id desc),'[]'::jsonb)
 into v_items
 from(
  select cf.id,cf.booking_id,
   concat_ws(' to ',pp.name,dst.name) route_name,
   cf.operator_id,o.name operator_name,
   cf.captain_id,nullif(trim(concat_ws(' ',c.first_name,c.last_name)),'') captain_name,
   cf.pickup_id,pp.name pickup_name,
   cf.destination_id,dst.name destination_name,
   cf.booking_experience_rating,cf.pace_shuttles_nps_score,cf.operator_rating,cf.captain_rating,cf.pickup_rating,cf.destination_rating,
   cf.went_well,cf.could_improve,cf.testimonial_consent,cf.created_at,
   coalesce(evidence.attribution_state,'unassigned') attribution_state
  from pace_v2.customer_feedback cf
  left join pace_v2.operators o on o.id=cf.operator_id
  left join pace_v2.captains c on c.id=cf.captain_id
  left join pace_v2.pickup_points pp on pp.id=cf.pickup_id
  left join pace_v2.destinations dst on dst.id=cf.destination_id
  left join(
   select qe.feedback_id,string_agg(distinct qe.source_attribution,', ' order by qe.source_attribution) attribution_state
   from pace_v2.quality_evidence qe
   group by qe.feedback_id
  ) evidence on evidence.feedback_id=cf.id
  order by cf.created_at desc,cf.id desc
  offset v_offset limit v_limit
 ) page_row;
 return jsonb_build_object('items',v_items,'total',v_total,'offset',v_offset,'limit',v_limit);
end
$evidence$;

revoke all on function public.v2_site_admin_quality_evidence_page(integer,integer) from public,anon,authenticated;
grant execute on function public.v2_site_admin_quality_evidence_page(integer,integer) to authenticated;
