import { NextRequest, NextResponse } from 'next/server';
import { dispatchDueCustomerEmails } from '@/lib/customer-email';

type SchedulerClient = {
  rpc: (name: string, args?: Record<string, unknown>) => PromiseLike<{
    data: unknown;
    error: { message: string } | null;
  }>;
};

type ScheduledOperationsDependencies = {
  env: NodeJS.ProcessEnv;
  now: () => string;
  createClient: (url: string, key: string, options: { auth: { persistSession: boolean } }) => SchedulerClient;
  dispatchDueCustomerEmails: typeof dispatchDueCustomerEmails;
};

export function createScheduledOperationsHandler(deps: ScheduledOperationsDependencies) {
  class SchedulerRpcError extends Error {}
  return async function scheduledOperations(req: NextRequest | Request) {
    const expected = deps.env.CRON_SECRET;
    const auth = req.headers.get('authorization');
    if (!expected || auth !== `Bearer ${expected}`) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    const url = deps.env.NEXT_PUBLIC_SUPABASE_URL;
    const key = deps.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!url || !key) return NextResponse.json({ error: 'Server configuration incomplete' }, { status: 500 });
    const supabase = deps.createClient(url, key, { auth: { persistSession: false } });
    const requestedAt=deps.now();
    const {data:beginData,error:beginError}=await supabase.rpc('v2_system_scheduler_begin',{p_execution_source:'scheduled',p_requested_at:requestedAt});
    if(beginError)return NextResponse.json({error:beginError.message},{status:500});
    const begin=Array.isArray(beginData)?beginData[0]:beginData as {run_id?:string;enabled?:boolean}|null;
    const runId=String(begin?.run_id||'');
    if(!runId)return NextResponse.json({error:'Scheduler run could not be started'},{status:500});
    if(begin?.enabled===false)return NextResponse.json({ok:true,status:'paused',runId});
    const partial:Record<string,unknown>={};
    const runPhase=async<T>(phase:string,operation:()=>Promise<T>)=>{
      const started=await supabase.rpc('v2_system_scheduler_phase_start',{p_run_id:runId,p_phase:phase});
      if(started.error)throw new SchedulerRpcError(started.error.message);
      let value:T;
      try{value=await operation()}
      catch(error:unknown){
        const message=error instanceof Error?error.message:'Scheduled phase failed';
        await supabase.rpc('v2_system_scheduler_phase_finish',{p_run_id:runId,p_phase:phase,p_result:{},p_failure_reason:message});
        throw error;
      }
      const finished=await supabase.rpc('v2_system_scheduler_phase_finish',{p_run_id:runId,p_phase:phase,p_result:value??{},p_failure_reason:null});
      if(finished.error)throw new SchedulerRpcError(finished.error.message);
      return value;
    };
    let data:unknown,t24Data:unknown,feedbackData:unknown;
    try{
      data=await runPhase('journey_operations',async()=>{const response=await supabase.rpc('v2_system_run_scheduled_operations',{p_t72_limit:100,p_t24_limit:100});if(response.error)throw new SchedulerRpcError(response.error.message);return response.data});
      partial.operations=data;
      t24Data=await runPhase('t24_communications',async()=>{const response=await supabase.rpc('v2_system_schedule_t24_journey_notifications',{p_as_of:requestedAt});if(response.error)throw new SchedulerRpcError(response.error.message);return response.data});
      partial.t24_queued=t24Data;
      feedbackData=await runPhase('feedback_communications',async()=>{const feedback=await supabase.rpc('v2_system_schedule_feedback_requests',{p_as_of:requestedAt,p_limit:100});if(feedback.error)throw new SchedulerRpcError(feedback.error.message);return feedback.data});
      partial.feedback_queued=feedbackData;
    }catch(error:unknown){
      const message=error instanceof Error?error.message:'Scheduled operations failed';
      await supabase.rpc('v2_system_scheduler_finish',{p_run_id:runId,p_result:partial,p_failure_reason:message});
      if(!(error instanceof SchedulerRpcError))throw error;
      return NextResponse.json({error:message},{status:500});
    }
    let emailResult = { claimed: 0, sent: 0, failed: 0 };
    try {
      emailResult = await runPhase('email_delivery',()=>deps.dispatchDueCustomerEmails(25));
      partial.emails=emailResult;
    } catch (error: unknown) {
      console.error('Customer email dispatch failed', error instanceof Error ? error.message : error);
      await supabase.rpc('v2_system_scheduler_finish',{p_run_id:runId,p_result:partial,p_failure_reason:'Customer email dispatch failed'});
      return NextResponse.json({ error: 'Customer email dispatch failed' }, { status: 503 });
    }
    const result=partial;
    const {error:finishError}=await supabase.rpc('v2_system_scheduler_finish',{p_run_id:runId,p_result:result,p_failure_reason:null});
    if(finishError)return NextResponse.json({error:finishError.message},{status:500});
    return NextResponse.json({ ok: true,status:'completed',runId, result: data, emails: emailResult });
  };
}
