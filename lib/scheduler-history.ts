export type SchedulerPhase={
 id?:string;phase:string;status:string;started_at:string;finished_at?:string|null;
 result?:unknown;failure_reason?:string|null;
};

export type SchedulerRun={
 id:string;status:string;execution_source:string;requested_at?:string;started_at:string;
 finished_at?:string|null;current_phase?:string|null;failure_phase?:string|null;
 failure_reason?:string|null;impact_summary?:string|null;resolution_summary?:string|null;
 result?:Record<string,any>;phases?:SchedulerPhase[];
};

const integer=(value:unknown)=>Number.isFinite(Number(value))?Number(value):0;

const PHASE_LABELS:Record<string,string>={
 journey_operations:'Journey operations',
 t24_communications:'T-24 communications',
 feedback_communications:'Feedback communications',
 email_delivery:'Email delivery',
};

export const phaseLabel=(phase:string)=>PHASE_LABELS[phase]||phase.replaceAll('_',' ');

export function schedulerRunDuration(run:Pick<SchedulerRun,'started_at'|'finished_at'>){
 if(!run.finished_at)return 'Running';
 const seconds=Math.max(0,Math.round((new Date(run.finished_at).getTime()-new Date(run.started_at).getTime())/1000));
 if(!Number.isFinite(seconds))return '—';
 const minutes=Math.floor(seconds/60),remaining=seconds%60;
 return minutes?`${minutes}m ${remaining}s`:`${remaining}s`;
}

export function schedulerRunSummary(run:Pick<SchedulerRun,'result'>){
 const result=run.result||{},operations=result.operations||result.journey_operations||{};
 const emails=result.emails||result.email_delivery||{};
 return [
  `Generated ${integer(operations.generated_departures)}`,
  `T-72 ${integer(operations.t72_processed)}`,
  `T-24 ${integer(operations.t24_processed)}`,
  `Closed ${integer(operations.closed_unrecorded)}`,
  `Emails ${integer(emails.sent)} sent / ${integer(emails.failed)} failed`,
 ].join(' · ');
}

export const schedulerRunImpact=(run:Pick<SchedulerRun,'impact_summary'>)=>run.impact_summary||'No recorded operational impact.';

export const schedulerRunResolution=(run:Pick<SchedulerRun,'status'|'resolution_summary'>)=>run.resolution_summary||(run.status==='failed'?'Unresolved':'No incident');

export function schedulerPhaseSummary(phase:SchedulerPhase){
 const value=phase.result;
 if(typeof value==='number')return `Processed ${value}`;
 if(!value||typeof value!=='object')return 'No count recorded';
 if(phase.phase==='journey_operations')return schedulerRunSummary({result:{operations:value}});
 if(phase.phase==='email_delivery'){
  const email=value as Record<string,unknown>;
  return `Claimed ${integer(email.claimed)} · Sent ${integer(email.sent)} · Failed ${integer(email.failed)}`;
 }
 const count=integer((value as Record<string,unknown>).queued??(value as Record<string,unknown>).count);
 return `Processed ${count}`;
}
