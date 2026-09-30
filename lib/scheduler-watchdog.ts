import {NextResponse} from 'next/server';

type WatchdogDependencies={
 env:NodeJS.ProcessEnv;
 recoverScheduledOperations?:(req:Request)=>Promise<Response>;
 now:()=>string;
 createClient:(url:string,key:string,options:{auth:{persistSession:boolean}})=>{rpc:(name:string,args?:Record<string,unknown>)=>PromiseLike<{data:any;error:{message:string}|null}>};
 dispatchMissingSlotAlerts:(limit?:number)=>Promise<{claimed:number;sent:number;failed:number}>;
};

export function createSchedulerWatchdogHandler(deps:WatchdogDependencies){
 return async function watchdog(req:Request){
  if(!deps.env.CRON_SECRET||req.headers.get('authorization')!==`Bearer ${deps.env.CRON_SECRET}`)
   return NextResponse.json({error:'Unauthorized'},{status:401});
  const url=deps.env.NEXT_PUBLIC_SUPABASE_URL,key=deps.env.SUPABASE_SERVICE_ROLE_KEY;
  if(!url||!key)return NextResponse.json({error:'Server configuration incomplete'},{status:500});
  try{
   const client=deps.createClient(url,key,{auth:{persistSession:false}});
   const result=await client.rpc('v2_system_detect_missing_scheduled_slots',{p_as_of:deps.now(),p_hours:168});
   if(result.error)throw new Error(result.error.message);
   let recovery:Record<string,unknown>|undefined;
   if(deps.recoverScheduledOperations){
    const response=await deps.recoverScheduledOperations(req);
    recovery=await response.json();
    if(!response.ok){await deps.dispatchMissingSlotAlerts(25);throw new Error('Scheduler recovery failed');}
    if(recovery?.status==='completed'){
     const refreshed=await client.rpc('v2_system_detect_missing_scheduled_slots',{p_as_of:deps.now(),p_hours:168});
     if(refreshed.error)throw new Error(refreshed.error.message);
    }
   }
   const alerts=await deps.dispatchMissingSlotAlerts(25);
   const data=result.data||{};
   return NextResponse.json({ok:true,missing:data.missing||0,resolved:data.resolved||0,alertsQueued:data.alerts_queued||0,alerts,...(recovery?{recovery}:{})});
  }catch(error){
   console.error('Scheduler watchdog failed',error instanceof Error?error.message:error);
   return NextResponse.json({error:'Scheduler watchdog failed'},{status:503});
  }
 };
}
