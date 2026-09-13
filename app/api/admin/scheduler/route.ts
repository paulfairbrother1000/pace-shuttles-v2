import {createClient} from '@supabase/supabase-js';
import {createAdminSchedulerHandler} from '@/lib/admin-scheduler-handler';
import {dispatchDueCustomerEmails} from '@/lib/customer-email';
export const runtime='nodejs';export const dynamic='force-dynamic';
const handler=createAdminSchedulerHandler({env:process.env,now:()=>new Date().toISOString(),createUserClient:(url,key,token)=>createClient(url,key,{global:{headers:{Authorization:`Bearer ${token}`}},auth:{persistSession:false}}) as any,createServiceClient:(url,key)=>createClient(url,key,{auth:{persistSession:false}}) as any,dispatchDueCustomerEmails});
export const GET=handler;export const POST=handler;
