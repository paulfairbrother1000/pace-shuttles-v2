import {createClient} from '@supabase/supabase-js';
import {createSchedulerWatchdogHandler} from '@/lib/scheduler-watchdog';
import {dispatchMissingSlotAlerts} from '@/lib/scheduler-missing-alerts';

export const runtime='nodejs';
export const dynamic='force-dynamic';

export const GET=createSchedulerWatchdogHandler({
 env:process.env,
 now:()=>new Date().toISOString(),
 createClient:(url,key,options)=>({rpc:(name,args)=>createClient(url,key,options).rpc(name as never,args as never)}),
 dispatchMissingSlotAlerts,
});
