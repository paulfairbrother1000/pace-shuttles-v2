'use client';

import './admin-clock-calendar.css';
import React,{useEffect,useState} from 'react';
import {Section,Status} from './ui';
import {eventLabel,formatJourneyTime,formatNextScheduledRun,schedulerRequest,sortEvents,statusLabel,type SchedulerModel} from '@/lib/admin-scheduler';
import {phaseLabel,schedulerPhaseSummary,schedulerRunDuration,schedulerRunImpact,schedulerRunResolution,schedulerRunSummary,type SchedulerRun} from '@/lib/scheduler-history';

const runTime=(value?:string|null)=>value?new Date(value).toLocaleString():'—';
const sourceLabel=(value:string)=>statusLabel(value||'scheduled');

function RunHistoryRow({run}:{run:SchedulerRun}){
 const [open,setOpen]=useState(false);
 const phases=run.phases||[];
 return <article className={`scheduler-run ${run.status}`}>
  <div className="scheduler-run-head">
   <div><Status value={statusLabel(run.status)}/><b>{sourceLabel(run.execution_source)} run</b><small>{runTime(run.started_at)} · {schedulerRunDuration(run)}</small></div>
   <button className="btn secondary" aria-label={`${open?'Hide':'Show'} details for ${run.status} ${run.execution_source} run`} onClick={()=>setOpen(value=>!value)}>{open?'Hide details':'Show details'}</button>
  </div>
  <p className="scheduler-run-summary">{schedulerRunSummary(run)}</p>
  {run.failure_reason?<p className="action-error"><b>{run.failure_phase?`${phaseLabel(run.failure_phase)} failed: `:'Failed: '}</b>{run.failure_reason}</p>:null}
  {run.status==='failed'?<div className="scheduler-impact"><p><b>Impact</b><br/>{schedulerRunImpact(run)}</p><p><b>Resolution</b><br/>{schedulerRunResolution(run)}</p></div>:null}
  {open?<div className="scheduler-phases">{phases.length?phases.map(phase=><div className="scheduler-phase" key={phase.id||phase.phase}><div><b>{phaseLabel(phase.phase)}</b><small>{runTime(phase.started_at)} · {schedulerRunDuration(phase)}</small></div><Status value={statusLabel(phase.status)}/><div><span>{schedulerPhaseSummary(phase)}</span>{phase.failure_reason?<small className="action-error">{phase.failure_reason}</small>:null}</div></div>):<p className="empty-state">Detailed phase evidence was not recorded for this earlier run.</p>}</div>:null}
 </article>;
}

export function AdminClockCalendar({initial,request=schedulerRequest}:{initial?:SchedulerModel;request?:(method?:string,body?:unknown)=>Promise<any>}){
 const [model,setModel]=useState<SchedulerModel|undefined>(initial),[error,setError]=useState(''),[busy,setBusy]=useState(false),[confirm,setConfirm]=useState(false),[reason,setReason]=useState('');
 const load=async()=>{try{const next=await request('GET');setModel(next)}catch(e){setError(e instanceof Error?e.message:'Unable to load scheduler')}};
 useEffect(()=>{if(!initial)void load()},[]);
 const enabled=!!model?.dashboard.control.enabled;
 const change=async()=>{if(enabled&&!reason.trim())return setError('Enter a reason for pausing the scheduler.');setBusy(true);setError('');try{await request('POST',{action:'set_enabled',enabled:!enabled,reason:reason.trim()});setConfirm(false);setReason('');await load()}catch(e){setError(e instanceof Error?e.message:'Scheduler could not be changed')}finally{setBusy(false)}};
 const trigger=async(eventType:string,bookingId:string)=>{if(!window.confirm('Run this event manually now? This does not prove real-time scheduling.'))return;setBusy(true);setError('');try{await request('POST',{action:'manual_trigger',eventType,bookingId});await load()}catch(e){setError(e instanceof Error?e.message:'Manual trigger failed')}finally{setBusy(false)}};
 if(!model)return <p role="status">Loading clock and calendar…</p>;
 const latest=model.dashboard.latest_run;
 const history=model.dashboard.recent_runs?.length?model.dashboard.recent_runs:(latest?[latest]:[]);
 return <div className="scheduler-admin">
  <Section title="Scheduled clock"><div className="scheduler-state"><div><Status value={enabled?'Scheduler ON':'Scheduler OFF'}/><p>{enabled?'Scheduled processing is running against the real clock.':'Scheduled work is paused. Due items will become overdue.'}</p>{model.dashboard.control.next_scheduled_run_at?<p><b>Next scheduled run</b><br/>{formatNextScheduledRun(model.dashboard.control.next_scheduled_run_at)}</p>:null}</div><button className={enabled?'btn danger':'btn'} disabled={busy} onClick={()=>setConfirm(true)} aria-label={`Turn scheduler ${enabled?'off':'on'}`}>Turn {enabled?'off':'on'}</button></div>{error?<p className="action-error" role="alert">{error}</p>:null}</Section>
  {confirm?<div className="modal-backdrop"><div className="card scheduler-dialog" role="dialog" aria-modal="true"><h2>{enabled?'Pause scheduled processing?':'Restart scheduled processing?'}</h2><p>{enabled?'Due communications and lifecycle events will wait until the scheduler is restarted.':'All overdue communications and lifecycle events will be processed immediately.'}</p>{enabled?<label>Reason for pausing<input aria-label="Reason for pausing" value={reason} onChange={e=>setReason(e.target.value)}/></label>:null}<div className="scheduler-actions"><button className="btn secondary" onClick={()=>setConfirm(false)}>Cancel</button><button className="btn" disabled={busy} onClick={change}>Confirm</button></div></div></div>:null}
  <Section title="Latest execution">{latest?<><p><b>{statusLabel(latest.status)}</b> · {runTime(latest.started_at)} · {schedulerRunDuration(latest)}</p><p>{schedulerRunSummary(latest)}</p>{latest.failure_reason?<p className="action-error">{latest.failure_reason}</p>:null}</>:<p className="empty-state">No scheduler runs recorded.</p>}</Section>
  <Section title="Execution history"><div className="scheduler-history">{history.map(run=><RunHistoryRow run={run} key={run.id}/>)}</div>{!history.length?<p className="empty-state">No scheduler runs recorded.</p>:null}</Section>
  <Section title="Calendar"><div className="scheduler-events">{sortEvents(model.events).map(row=><article className="scheduler-event" key={row.event_key}><div><b>{row.route_name}</b><small>{eventLabel(row.event_type)} · {formatJourneyTime(row.due_at,row.journey_timezone)}</small></div><div><Status value={statusLabel(row.status)}/><small>{row.execution_source==='manual'?'Manual':'Scheduled'}</small><button className="btn secondary" disabled={busy} onClick={()=>trigger(row.event_type,row.booking_id)}>Run manually</button></div>{row.failure_reason?<p className="action-error">{row.failure_reason}</p>:null}</article>)}</div>{!model.events.length?<p className="empty-state">No scheduled events in this window.</p>:null}</Section>
 </div>;
}
