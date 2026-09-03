'use client';

import React,{useEffect,useMemo,useRef,useState} from 'react';
import {captainEndLeg,captainStartLeg} from '@/lib/data';
import {captainDutyState,formatPartyComposition,nextLegAction,selectCurrentDuty,type CaptainTodayDuty} from '@/lib/captain-today';

export interface CaptainTodayManifestPassenger{
 first_name?:string|null;
 last_name?:string|null;
 age_group?:string|null;
 notes?:string|null;
}

/** A grouped booking-party row from the protected Today manifest projection. */
export interface CaptainTodayManifestRow{
 duty_id:string;
 confirmed_allocation_id:string;
 booking_id:string;
 lead_passenger_name:string;
 adult_count:number;
 child_count:number;
 infant_count:number;
 payment_status:string;
 special_requirements_present:boolean;
 unread_count:number;
 passengers:CaptainTodayManifestPassenger[]|string;
}

export interface CaptainTodayDutyRow extends CaptainTodayDuty{
 pickup_name:string;
 leg_1_name:string;
 leg_1_scheduled_arrival_ts:string|Date|null;
 leg_2_name?:string|null;
 leg_2_scheduled_arrival_ts?:string|Date|null;
 vehicle_name:string;
 operator_name:string;
 leg_1_started_by_user_id?:string|null;
 leg_1_ended_by_user_id?:string|null;
 leg_1_notes?:string|null;
 leg_1_incident_summary?:string|null;
 leg_2_started_by_user_id?:string|null;
 leg_2_ended_by_user_id?:string|null;
 leg_2_notes?:string|null;
 leg_2_incident_summary?:string|null;
}

export interface CaptainTodayProps{
 duties:readonly CaptainTodayDutyRow[];
 manifest:readonly CaptainTodayManifestRow[];
 /** Controlled selected allocation/duty identity. Completed duties can be selected too. */
 selectedDutyId?:string;
 onSelectedDutyIdChange:(dutyId:string)=>void;
 now?:Date;
 onMessageParty?:(party:CaptainTodayManifestRow)=>void;
 communications?:React.ReactNode;
 /** Returns the full protected Today snapshot for this selection/request. */
 onReload:(request:CaptainTodayReloadRequest)=>Promise<CaptainTodayReloadResult>;
 actions?:CaptainTodayActions;
}

export interface CaptainTodayReloadRequest{dutyId:string;requestId:string;signal:AbortSignal}
export interface CaptainTodayReloadResult{duties:readonly CaptainTodayDutyRow[];manifest:readonly CaptainTodayManifestRow[]}

export type CaptainTodayActionResult={data?:unknown;error?:unknown};
export interface CaptainTodayActions{
 startLeg:(departureId:string)=>Promise<CaptainTodayActionResult>;
 endLeg:(departureId:string,state:'normal'|'incident',notes:string,summary:string)=>Promise<CaptainTodayActionResult>;
}
export const defaultCaptainTodayActions:CaptainTodayActions={startLeg:captainStartLeg,endLeg:captainEndLeg};

const dutyKey=(duty:CaptainTodayDutyRow)=>duty.duty_id||duty.confirmed_allocation_id||duty.id||'';
const title=(duty:CaptainTodayDutyRow)=>duty.leg_1_name?.trim()||'Today’s duty';

function local(value:string|Date|null|undefined,timezone:string,options:Intl.DateTimeFormatOptions){
 if(!value)return '—';
 const date=value instanceof Date?value:new Date(value);
 if(Number.isNaN(date.getTime()))return '—';
 try{return new Intl.DateTimeFormat('en-GB',{timeZone:timezone,...options}).format(date)}catch{return new Intl.DateTimeFormat('en-GB',options).format(date)}
}

function localTime(duty:CaptainTodayDutyRow,value:string|Date|null|undefined){return local(value,duty.country_timezone,{hour:'2-digit',minute:'2-digit',hour12:false})}
function localDate(duty:CaptainTodayDutyRow){return local(duty.first_scheduled_departure_ts,duty.country_timezone,{weekday:'short',day:'numeric',month:'short',year:'numeric'})}

function stateLabel(duty:CaptainTodayDutyRow){
 switch(captainDutyState(duty)){
  case 'ready':return 'Ready';
  case 'leg_1_in_progress':return 'Leg 1 active';
  case 'awaiting_leg_2':return 'At destination';
  case 'leg_2_in_progress':return 'Leg 2 active';
  case 'completed':return 'Completed';
  case 'incident':return 'Incident';
  default:return 'Status needs review';
 }
}

function parsedPassengers(value:CaptainTodayManifestRow['passengers']):CaptainTodayManifestPassenger[]{
 if(Array.isArray(value))return value;
 if(typeof value!=='string')return [];
 try{const parsed=JSON.parse(value);return Array.isArray(parsed)?parsed:[]}catch{return []}
}

function passengerName(passenger:CaptainTodayManifestPassenger){
 return [passenger.first_name,passenger.last_name].filter((part):part is string=>typeof part==='string'&&part.trim()!=='').join(' ')||'Passenger';
}

function partyId(party:CaptainTodayManifestRow,index:number){return party.booking_id||`${party.duty_id||party.confirmed_allocation_id||'party'}-${index}`}

function DutySelector({duties,selectedId,onSelect,disabled}:{duties:readonly CaptainTodayDutyRow[];selectedId:string;onSelect:(id:string)=>void;disabled:boolean}){
 if(duties.length<2)return null;
 return <section className="captain-duty-selector" aria-labelledby="other-duties-heading">
  <h2 id="other-duties-heading">Today’s duties</h2>
  <div className="captain-duty-list">
   {duties.map(duty=>{const id=dutyKey(duty),selected=id===selectedId;return <button type="button" disabled={disabled} key={id||`${title(duty)}-${duty.first_scheduled_departure_ts}`} className={`captain-duty-option${selected?' selected':''}`} aria-pressed={selected} onClick={()=>id&&onSelect(id)}>
    <span><b>{title(duty)}</b><small>{localTime(duty,duty.first_scheduled_departure_ts)} · {duty.vehicle_name||'Vehicle to be confirmed'}</small></span>
    <span className={`captain-duty-state state-${captainDutyState(duty)}`}>{stateLabel(duty)}</span>
   </button>})}
  </div>
 </section>;
}

function Manifest({rows,onMessageParty}:{rows:readonly CaptainTodayManifestRow[];onMessageParty?:CaptainTodayProps['onMessageParty']}){
 const [expanded,setExpanded]=useState<string|null>(null);
 return <section id="manifest" className="captain-today-section" aria-labelledby="manifest-heading">
  <div className="captain-section-head"><h2 id="manifest-heading">Manifest</h2><span>{rows.length} {rows.length===1?'party':'parties'}</span></div>
  {rows.map((party,index)=>{const id=partyId(party,index),open=expanded===id,passengers=parsedPassengers(party.passengers),composition=formatPartyComposition(party)||'Passenger composition not recorded';return <article className="captain-party" key={id}>
   <button type="button" className="captain-party-toggle" aria-expanded={open} aria-controls={`${id}-details`} onClick={()=>setExpanded(open?null:id)}>
    <span><b>{party.lead_passenger_name||'Booking party'}</b><small>{composition}</small></span>
    <span className="captain-party-summary"><strong className="captain-payment">{String(party.payment_status||'payment pending').toUpperCase()}</strong>{party.special_requirements_present?<small className="captain-requirement">Requirements noted</small>:null}{Number(party.unread_count||0)>0?<small className="captain-unread">Unread {Number(party.unread_count)}</small>:null}<span aria-hidden="true">{open?'−':'+'}</span></span>
   </button>
   {open?<div id={`${id}-details`} className="captain-party-details">
    <h3>Passengers</h3>
    <ul>{passengers.map((passenger,passengerIndex)=><li key={`${passengerName(passenger)}-${passengerIndex}`}><b>{passengerName(passenger)}</b><span>{String(passenger.age_group||'adult')}</span>{passenger.notes?.trim()?<small>{passenger.notes}</small>:null}</li>)}</ul>
    {!passengers.length?<p className="captain-empty">Passenger details are not available yet.</p>:null}
    {onMessageParty?<button type="button" className="btn secondary captain-message-party" onClick={()=>onMessageParty(party)}>Message a party</button>:<p className="captain-message-handoff">Message a party is available in Communications.</p>}
   </div>:null}
  </article>})}
  {!rows.length?<p className="captain-empty">No booking parties are currently allocated to this duty.</p>:null}
 </section>;
}

type CompletionDraft={state:'normal'|'incident';notes:string;summary:string;error:string};
const blankDraft=():CompletionDraft=>({state:'normal',notes:'',summary:'',error:''});
const resultMessage=(error:unknown)=>error instanceof Error?error.message:String(error||'Unable to record this timing action.');

function LegSection({duty,leg,nextAction,busy,onStart,onOpenEnd,endOpen,draft,onDraftChange,onCancelEnd,onRecordEnd}:{
 duty:CaptainTodayDutyRow;leg:1|2;nextAction:ReturnType<typeof nextLegAction>;busy:boolean;
 onStart:(duty:CaptainTodayDutyRow,leg:1|2)=>void;onOpenEnd:(duty:CaptainTodayDutyRow,leg:1|2)=>void;endOpen:boolean;draft:CompletionDraft;
 onDraftChange:(change:Partial<CompletionDraft>)=>void;onCancelEnd:()=>void;onRecordEnd:(duty:CaptainTodayDutyRow,leg:1|2)=>void;
}){
 const name=leg===1?duty.leg_1_name:duty.leg_2_name;
 const departure=leg===1?duty.leg_1_scheduled_departure_ts:duty.leg_2_scheduled_departure_ts;
 const arrival=leg===1?duty.leg_1_scheduled_arrival_ts:duty.leg_2_scheduled_arrival_ts;
 const started=leg===1?duty.leg_1_started_at:duty.leg_2_started_at;
 const ended=leg===1?duty.leg_1_ended_at:duty.leg_2_ended_at;
 const completion=leg===1?duty.leg_1_completion_state:duty.leg_2_completion_state;
 const configured=Boolean(name);
 const state=!configured?'Not configured':completion==='incident'?'Incident':ended?'Completed':started?'Under way':'Scheduled';
 const canStart=configured&&!busy&&nextAction?.leg===leg&&nextAction.action==='start';
 const canEnd=configured&&!busy&&nextAction?.leg===leg&&nextAction.action==='end';
 return <section id={`leg-${leg}`} className="captain-today-section captain-leg" aria-labelledby={`leg-${leg}-heading`}>
  <div className="captain-section-head"><h2 id={`leg-${leg}-heading`}>Leg {leg}</h2><span>{state}</span></div>
  {name?<><p><b>{name}</b><br/><small>Departs {localTime(duty,departure)} · Expected arrival {localTime(duty,arrival)}</small></p>
   {started?<p className="captain-leg-evidence"><b>Actual departure {localTime(duty,started)}</b></p>:null}
   {ended?<p className="captain-leg-evidence"><b>Actual arrival {localTime(duty,ended)}</b></p>:null}
   <div className="captain-leg-actions">
    <button type="button" className="btn secondary" disabled={!canStart} onClick={()=>onStart(duty,leg)}>Start Leg {leg}</button>
    <button type="button" className="btn" disabled={!canEnd} onClick={()=>onOpenEnd(duty,leg)}>End Leg {leg}</button>
   </div>
   {endOpen?<form className="captain-completion-panel" aria-labelledby={`leg-${leg}-completion-heading`} onSubmit={event=>{event.preventDefault();onRecordEnd(duty,leg)}}>
    <h3 id={`leg-${leg}-completion-heading`}>Record Leg {leg} end</h3>
    <p>Record the actual arrival time for <b>Leg {leg}: {name}</b>.</p>
    <fieldset disabled={busy}><legend>Completion</legend>
     <label><input type="radio" name={`leg-${leg}-completion`} checked={draft.state==='normal'} onChange={()=>onDraftChange({state:'normal',summary:'',error:''})}/> Normal completion</label>
     <label><input type="radio" name={`leg-${leg}-completion`} checked={draft.state==='incident'} onChange={()=>onDraftChange({state:'incident',error:''})}/> Incident</label>
    </fieldset>
    <label>Journey notes (optional)<textarea value={draft.notes} onChange={event=>onDraftChange({notes:event.target.value,error:''})} disabled={busy}/></label>
    {draft.state==='incident'?<label>Incident summary<textarea aria-required="true" value={draft.summary} onChange={event=>onDraftChange({summary:event.target.value,error:''})} disabled={busy}/></label>:null}
    {draft.error?<p className="action-error" role="alert">{draft.error}</p>:null}
    <div className="captain-completion-actions"><button type="button" className="btn secondary" disabled={busy} onClick={onCancelEnd}>Cancel</button><button type="submit" className="btn" disabled={busy}>Record end time</button></div>
   </form>:null}
  </>:<p className="captain-empty">Leg {leg} is not configured for this one-way duty.</p>}
 </section>;
}

type PendingRefresh={
 dutyId:string;allocationId:string;key:string;leg:1|2;action:'start'|'end';
 completion?:'normal'|'incident';notes?:string;summary?:string|null;evidenceTimestamp?:number;
 leg1DepartureId:string|null;leg2DepartureId:string|null;
};
type ActiveReload={requestId:string;dutyId:string;controller:AbortController};
type ActiveOperation={epoch:number;dutyId:string};

/** Mobile-first Today view with verified server-authoritative leg transitions. */
export function CaptainToday({duties,manifest,selectedDutyId,onSelectedDutyIdChange,now=new Date(),onMessageParty,communications,onReload,actions=defaultCaptainTodayActions}:CaptainTodayProps){
 const [snapshot,setSnapshot]=useState<CaptainTodayReloadResult|null>(null);
 const visibleDuties=snapshot?.duties||duties,visibleManifest=snapshot?.manifest||manifest;
 const automatic=useMemo(()=>selectCurrentDuty(visibleDuties,now),[visibleDuties,now]);
 const selected=useMemo(()=>visibleDuties.find(duty=>dutyKey(duty)===selectedDutyId)||automatic||visibleDuties[0],[automatic,visibleDuties,selectedDutyId]);
 const selectedId=selected?dutyKey(selected):'';
 const selectedIdRef=useRef(selectedId),saving=useRef(false),openEndRef=useRef<string|null>(null),requestSequence=useRef(0),activeReload=useRef<ActiveReload|null>(null),mounted=useRef(true),operationSequence=useRef(0),activeOperation=useRef<ActiveOperation|null>(null);
 selectedIdRef.current=selectedId;
 const [busy,setBusy]=useState(false),[openEnd,setOpenEnd]=useState<string|null>(null),[drafts,setDrafts]=useState<Record<string,CompletionDraft>>({}),[actionErrors,setActionErrors]=useState<Record<string,string>>({}),[pendingRefresh,setPendingRefresh]=useState<PendingRefresh|null>(null);
 openEndRef.current=openEnd;
 const invalidateOperation=(releaseUi:boolean)=>{
  operationSequence.current+=1;activeOperation.current=null;saving.current=false;
  if(releaseUi&&mounted.current)setBusy(false);
 };
 const operationIsCurrent=(operation:ActiveOperation)=>mounted.current&&activeOperation.current?.epoch===operation.epoch&&activeOperation.current.dutyId===operation.dutyId&&selectedIdRef.current===operation.dutyId;
 const beginOperation=(dutyId:string)=>{const operation={epoch:++operationSequence.current,dutyId};activeOperation.current=operation;saving.current=true;setBusy(true);return operation;};
 const release=(operation:ActiveOperation)=>{if(!operationIsCurrent(operation))return;activeOperation.current=null;saving.current=false;setBusy(false)};
 useEffect(()=>{setSnapshot(null)},[duties,manifest]);
 useEffect(()=>{
  activeReload.current?.controller.abort();activeReload.current=null;
  invalidateOperation(true);
  setOpenEnd(current=>current?.startsWith(`${selectedId}:`)?current:null);
 },[selectedId]);
 useEffect(()=>{setOpenEnd(current=>{
  if(!current||!selected)return null;
  const [dutyId,legText]=current.split(':'),leg=Number(legText) as 1|2,action=nextLegAction(selected,now);
  return dutyId===selectedId&&action?.leg===leg&&action.action==='end'?current:null;
 })},[selected,selectedId,now]);
 useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;operationSequence.current+=1;activeReload.current?.controller.abort();activeReload.current=null;activeOperation.current=null;saving.current=false;}},[]);
 const partyRows=selected?visibleManifest.filter(row=>(row.duty_id||row.confirmed_allocation_id)===selectedId):[];
 const keyFor=(duty:CaptainTodayDutyRow,leg:1|2)=>`${dutyKey(duty)}:${leg}`;
 const updateDraft=(key:string,change:Partial<CompletionDraft>)=>setDrafts(current=>({...current,[key]:{...(current[key]||blankDraft()),...change}}));
 const errorFor=(pending:PendingRefresh,message:string)=>{
  if(pending.action==='end')updateDraft(pending.key,{error:message});else setActionErrors(current=>({...current,[pending.key]:message}));
 };
 const timestamp=(value:unknown)=>{const time=value instanceof Date?value.getTime():typeof value==='string'?Date.parse(value):NaN;return Number.isFinite(time)?time:undefined};
 const operationIndex=(pending:PendingRefresh)=>pending.leg===1?(pending.action==='start'?1:2):(pending.action==='start'?3:4);
 const payloadShapeIsValid=(row:CaptainTodayDutyRow)=>{
  const valid=(ended:CaptainTodayDuty['leg_1_ended_at'],completion:string|null|undefined,summary:string|null|undefined)=>{
   if(!ended)return completion==null&&summary==null;
   if(completion==='normal')return summary==null;
   return completion==='incident'&&typeof summary==='string'&&summary.trim()!=='';
  };
  return valid(row.leg_1_ended_at,row.leg_1_completion_state,row.leg_1_incident_summary)
   &&valid(row.leg_2_ended_at,row.leg_2_completion_state,row.leg_2_incident_summary);
 };
 const stateIsSameOrLater=(row:CaptainTodayDutyRow,pending:PendingRefresh)=>{
  const state=captainDutyState(row),submittedIndex=operationIndex(pending);
  if(state==='invalid'||!payloadShapeIsValid(row))return false;
  if(state==='incident'){
   const incidentIndex=row.leg_1_completion_state==='incident'?2:row.leg_2_completion_state==='incident'?4:undefined;
   return incidentIndex!==undefined&&(pending.completion==='incident'?incidentIndex===submittedIndex:incidentIndex>submittedIndex);
  }
  if(pending.completion==='incident')return false;
  const progress={ready:0,leg_1_in_progress:1,awaiting_leg_2:2,leg_2_in_progress:3,completed:4}[state];
  return progress>=submittedIndex;
 };
 const evidenceIsExpected=(row:CaptainTodayDutyRow,pending:PendingRefresh)=>{
  const started=pending.leg===1?row.leg_1_started_at:row.leg_2_started_at,ended=pending.leg===1?row.leg_1_ended_at:row.leg_2_ended_at;
  if(pending.evidenceTimestamp===undefined
     || row.confirmed_allocation_id!==pending.allocationId
     || (row.leg_1_departure_id??null)!==pending.leg1DepartureId
     || (row.leg_2_departure_id??null)!==pending.leg2DepartureId
     || !stateIsSameOrLater(row,pending))return false;
  const evidence=pending.action==='start'?started:ended;
  if(timestamp(evidence)!==pending.evidenceTimestamp)return false;
  if(pending.action==='start')return true;
  const completion=pending.leg===1?row.leg_1_completion_state:row.leg_2_completion_state;
  const notes=pending.leg===1?row.leg_1_notes:row.leg_2_notes;
  const summary=pending.leg===1?row.leg_1_incident_summary:row.leg_2_incident_summary;
  return completion===pending.completion&&notes===pending.notes&&(summary??null)===pending.summary;
 };
 const terminalAbsenceIsExpected=(result:CaptainTodayReloadResult,pending:PendingRefresh)=>{
  if(pending.action!=='end'||pending.leg!==2||pending.evidenceTimestamp===undefined||!pending.dutyId||!pending.allocationId||!pending.leg1DepartureId||!pending.leg2DepartureId)return false;
  const conflicts=(row:CaptainTodayDutyRow)=>dutyKey(row)===pending.dutyId||row.confirmed_allocation_id===pending.allocationId;
  const staleManifest=result.manifest.some(row=>(row.duty_id||row.confirmed_allocation_id)===pending.dutyId||row.confirmed_allocation_id===pending.allocationId);
  return !result.duties.some(conflicts)&&!staleManifest;
 };
 const refresh=async(pending:PendingRefresh,operation:ActiveOperation)=>{
  if(!operationIsCurrent(operation))return false;
  const requestId=`${pending.dutyId}:${++requestSequence.current}`,controller=new AbortController();
  activeReload.current?.controller.abort();activeReload.current={requestId,dutyId:pending.dutyId,controller};
  try{
   if(!operationIsCurrent(operation))return false;
   const result=await onReload({dutyId:pending.dutyId,requestId,signal:controller.signal});
   if(!operationIsCurrent(operation))return false;
   if(controller.signal.aborted||selectedIdRef.current!==pending.dutyId)throw new Error('Authoritative refresh is stale for the selected duty.');
   if(!result||!Array.isArray(result.duties)||!Array.isArray(result.manifest))throw new Error('Authoritative refresh returned an invalid snapshot.');
   const refreshed=result.duties.find(row=>dutyKey(row)===pending.dutyId);
   const acceptedTerminalAbsence=!refreshed&&terminalAbsenceIsExpected(result,pending);
   if(!acceptedTerminalAbsence&&(!refreshed||!evidenceIsExpected(refreshed,pending)))throw new Error('Authoritative refresh did not include the expected timing evidence.');
   setSnapshot({duties:result.duties,manifest:result.manifest});setPendingRefresh(current=>current?.key===pending.key?null:current);
   if(pending.action==='end'){
    if(acceptedTerminalAbsence){setDrafts(current=>{const next={...current};delete next[pending.key];return next;});setActionErrors(current=>{const next={...current};delete next[pending.key];return next;});onSelectedDutyIdChange('');}
    else updateDraft(pending.key,{error:''});
    if(openEndRef.current===pending.key)setOpenEnd(null);
   }else setActionErrors(current=>({...current,[pending.key]:''}));
   return true;
  }catch(error){if(!operationIsCurrent(operation))return false;errorFor(pending,`Could not refresh authoritative timing evidence: ${resultMessage(error)}`);setPendingRefresh(pending);return false;
  }finally{if(!operationIsCurrent(operation))return;if(activeReload.current?.requestId===requestId)activeReload.current=null;release(operation);}
 };
 const choose=(id:string)=>{if(!saving.current)onSelectedDutyIdChange(id)};
 const start=async(duty:CaptainTodayDutyRow,leg:1|2)=>{
  const action=nextLegAction(duty,now),departureId=leg===1?duty.leg_1_departure_id:duty.leg_2_departure_id,key=keyFor(duty,leg),pending:PendingRefresh={dutyId:dutyKey(duty),allocationId:duty.confirmed_allocation_id||'',key,leg,action:'start',leg1DepartureId:duty.leg_1_departure_id??null,leg2DepartureId:duty.leg_2_departure_id??null};
  if(saving.current||pendingRefresh?.dutyId===pending.dutyId||action?.leg!==leg||action.action!=='start'||!departureId)return;
  if(!window.confirm(`Start Leg ${leg}: ${leg===1?duty.leg_1_name:duty.leg_2_name}? This records the actual departure time.`))return;
  const operation=beginOperation(pending.dutyId);setActionErrors(current=>({...current,[key]:''}));
  try{
   const result=await actions.startLeg(departureId);if(!operationIsCurrent(operation))return;if(result.error)throw result.error;
   pending.evidenceTimestamp=timestamp(result.data);
   if(pending.evidenceTimestamp===undefined)throw new Error('Timing action did not return its authoritative server timestamp.');
   await refresh(pending,operation);
  }catch(error){if(!operationIsCurrent(operation))return;setActionErrors(current=>({...current,[key]:resultMessage(error)}));release(operation);}
 };
 const recordEnd=async(duty:CaptainTodayDutyRow,leg:1|2)=>{
  const action=nextLegAction(duty,now),departureId=leg===1?duty.leg_1_departure_id:duty.leg_2_departure_id,key=keyFor(duty,leg),draft=drafts[key]||blankDraft(),summary=draft.state==='incident'?draft.summary:'',pending:PendingRefresh={dutyId:dutyKey(duty),allocationId:duty.confirmed_allocation_id||'',key,leg,action:'end',completion:draft.state,notes:draft.notes,summary:draft.state==='incident'?draft.summary:null,leg1DepartureId:duty.leg_1_departure_id??null,leg2DepartureId:duty.leg_2_departure_id??null};
  if(saving.current||pendingRefresh?.dutyId===pending.dutyId||action?.leg!==leg||action.action!=='end'||!departureId)return;
  if(draft.state==='incident'&&!draft.summary.trim()){updateDraft(key,{error:'An incident summary is required.'});return;}
  const operation=beginOperation(pending.dutyId);updateDraft(key,{error:''});
  try{
   const result=await actions.endLeg(departureId,draft.state,draft.notes,summary);if(!operationIsCurrent(operation))return;if(result.error)throw result.error;
   pending.evidenceTimestamp=timestamp(result.data);
   if(pending.evidenceTimestamp===undefined)throw new Error('Timing action did not return its authoritative server timestamp.');
   await refresh(pending,operation);
  }catch(error){if(!operationIsCurrent(operation))return;updateDraft(key,{error:resultMessage(error)});release(operation);}
 };
 const retryRefresh=()=>{if(!pendingRefresh||saving.current)return;const operation=beginOperation(pendingRefresh.dutyId);void refresh(pendingRefresh,operation)};

 if(!selected)return <section className="captain-today-empty" aria-labelledby="today-heading"><h2 id="today-heading">Today</h2><p>No duties are assigned for today.</p></section>;
 const selectedPending=pendingRefresh?.dutyId===selectedId;
 return <div className="captain-today">
  <nav className="captain-today-tabs" aria-label="Today sections"><a href="#manifest">Manifest</a><a href="#leg-1">Leg 1</a>{selected.leg_2_departure_id?<a href="#leg-2">Leg 2</a>:<span aria-disabled="true">Leg 2</span>}<a href="#communications">Communications</a></nav>
  <header className="captain-duty-header">
   <div><p className="captain-date">{localDate(selected)}</p><h1>{title(selected)}</h1><p className="captain-pickup"><b>Pickup</b> · {localTime(selected,selected.first_scheduled_departure_ts)} · {selected.pickup_name}</p><p className="captain-vehicle">{selected.vehicle_name||'Vehicle to be confirmed'} · {selected.operator_name||'Operator to be confirmed'}</p></div>
   <strong className={`captain-duty-state state-${captainDutyState(selected)}`}>{stateLabel(selected)}</strong>
  </header>
  <DutySelector duties={visibleDuties} selectedId={selectedId} onSelect={choose} disabled={busy}/>
  <Manifest rows={partyRows} onMessageParty={onMessageParty}/>
  {[1,2].map(leg=>{const typedLeg=leg as 1|2,key=keyFor(selected,typedLeg),next=nextLegAction(selected,now),endIsCurrent=next?.leg===typedLeg&&next.action==='end';return <LegSection key={typedLeg} duty={selected} leg={typedLeg} nextAction={selectedPending?undefined:next} busy={busy} onStart={start} onOpenEnd={(duty,number)=>setOpenEnd(keyFor(duty,number))} endOpen={openEnd===key&&endIsCurrent} draft={drafts[key]||blankDraft()} onDraftChange={change=>updateDraft(key,change)} onCancelEnd={()=>setOpenEnd(null)} onRecordEnd={recordEnd}/>})}
  {selectedPending?<p className="action-error" role="alert">{pendingRefresh.action==='end'?(drafts[pendingRefresh.key]||blankDraft()).error:actionErrors[pendingRefresh.key]} <button type="button" className="btn secondary" onClick={retryRefresh} disabled={busy}>Refresh timing evidence</button></p>:null}
  {!selectedPending&&(actionErrors[keyFor(selected,1)]||actionErrors[keyFor(selected,2)])?<p className="action-error" role="alert">{actionErrors[keyFor(selected,1)]||actionErrors[keyFor(selected,2)]}</p>:null}
  <section id="communications" className="captain-today-section" aria-labelledby="communications-heading"><div className="captain-section-head"><h2 id="communications-heading">Communications</h2></div>{communications||<p className="captain-empty">Party messaging and journey-wide updates are available here.</p>}</section>
 </div>;
}
