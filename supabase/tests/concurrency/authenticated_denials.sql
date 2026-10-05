-- Run after synthetic completion only, never production.
begin; set local role authenticated;select set_config('request.jwt.claim.sub','f1000000-0000-0000-0000-000000000104',true);
do $test$ begin
 begin perform public.v2_captain_end_leg('f1000000-0000-0000-0000-000000000031'::uuid,'normal',null,null,'f1000000-0000-0000-0000-000000000051'::uuid);raise exception 'unauthorized end accepted'; exception when others then if sqlerrm<>'captain assignment required' then raise; end if; end;
 begin perform public.v2_site_admin_quality_dashboard();raise exception 'customer read admin quality dashboard';exception when others then if sqlerrm<>'site admin required' then raise;end if;end;
 begin perform public.v2_customer_submit_feedback('f1000000-0000-0000-0000-000000000080'::uuid,5,10,5,3,5,5,null,null,false);raise exception 'non-owner submitted feedback';exception when others then if sqlerrm<>'eligible paid booking owned by the authenticated customer required' then raise;end if;end;
 if exists(select 1 from public.v2_captain_today_manifest) then raise exception 'foreign captain read manifest';end if;
end $test$;rollback; select 'authenticated role unauthorized cases passed' as result;
