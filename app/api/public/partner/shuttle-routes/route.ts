import { createClient } from '@supabase/supabase-js';
import { NextRequest, NextResponse } from 'next/server';

export const runtime='nodejs';
export const dynamic='force-dynamic';

type PartnerCatalogue={
  authorized?:boolean;
  rate_limited?:boolean;
  partner?:{id:string;name:string};
  tiles?:unknown[];
};

export async function GET(request:NextRequest){
  const apiKey=request.headers.get('x-pace-api-key')?.trim();
  const url=process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey=process.env.SUPABASE_SERVICE_ROLE_KEY;
  if(!url||!serviceRoleKey){
    return NextResponse.json({error:'Server configuration incomplete'},{status:500});
  }

  const supabase=createClient(url,serviceRoleKey,{auth:{persistSession:false}});
  const forwardedFor=request.headers.get('x-vercel-forwarded-for')
    ??request.headers.get('x-forwarded-for')?.split(',')[0]
    ??'unknown';
  const fingerprint=`${forwardedFor}|${request.headers.get('user-agent')??'unknown'}`;
  const {data:withinLimit,error:limitError}=await supabase.rpc(
    'v2_system_check_partner_api_rate_limit',
    {p_client_fingerprint:fingerprint},
  );
  if(limitError){
    console.error('Partner API rate-limit check failed',limitError.message);
    return NextResponse.json({error:'Unable to load shuttle routes'},{status:500});
  }
  if(!withinLimit){
    return NextResponse.json({error:'Rate limit exceeded'},{status:429,headers:{'Retry-After':'60'}});
  }
  if(!apiKey){
    return NextResponse.json({error:'Pace API key required'},{status:401});
  }

  const {data,error}=await supabase.rpc('v2_system_partner_shuttle_catalog',{p_api_key:apiKey});
  if(error){
    console.error('Partner shuttle catalogue failed',error.message);
    return NextResponse.json({error:'Unable to load shuttle routes'},{status:500});
  }

  const catalogue=(data??{}) as PartnerCatalogue;
  if(!catalogue.authorized){
    return NextResponse.json({error:'Invalid or inactive Pace API key'},{status:403});
  }
  if(catalogue.rate_limited){
    return NextResponse.json({error:'Rate limit exceeded'},{status:429,headers:{'Retry-After':'60'}});
  }

  return NextResponse.json({
    build_tag:'pace-v2-partner-catalogue-v1',
    partner:catalogue.partner,
    tiles:Array.isArray(catalogue.tiles)?catalogue.tiles:[],
  },{headers:{'Cache-Control':'private, no-store'}});
}
