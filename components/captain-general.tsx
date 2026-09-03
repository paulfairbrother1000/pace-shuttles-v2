import React from 'react';
import {Section,Status} from './ui';

type CaptainJourney=Record<string,any>;

const norm=(value:unknown)=>String(value||'').toLowerCase();
const when=(value:unknown)=>value?new Date(value as string).toLocaleString([],{weekday:'short',day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'}):'—';
const allocationId=(journey:CaptainJourney)=>String(journey.confirmed_allocation_id||journey.captain_assignment_id||'');
const completed=(journey:CaptainJourney)=>Boolean(journey.actual_arrival_ts)||['completed','cancelled'].includes(norm(journey.departure_status));
const confirmed=(journey:CaptainJourney)=>Boolean(journey.actual_departure_ts)||['confirmed','active'].includes(norm(journey.departure_status));
const state=(journey:CaptainJourney)=>journey.actual_arrival_ts?'COMPLETED':journey.actual_departure_ts?'ACTIVE':String(journey.departure_status||'POSSIBLE').toUpperCase();
const scheduledTime=(journey:CaptainJourney)=>{const value=new Date(journey.scheduled_departure_ts).getTime();return Number.isFinite(value)?value:undefined};

function JourneyRows({rows,empty,today=false,onOpenToday}:{rows:readonly CaptainJourney[];empty:string;today?:boolean;onOpenToday?:()=>void}){
 return <>{rows.map((journey,index)=>{const id=allocationId(journey)||`${journey.route_name}-${index}`;return <article className="captain-general-journey notice" key={id}>
  <span><b>{journey.route_name||'Journey'}</b><small>{when(journey.scheduled_departure_ts)} · {journey.vehicle_name||'Vehicle to be confirmed'} · {journey.operator_name||'Operator to be confirmed'}</small></span>
  <span><Status value={state(journey)}/>{today?<a className="btn secondary" href="/captain?tab=today" onClick={event=>{event.preventDefault();onOpenToday?.()}}>Open in Today</a>:null}</span>
 </article>})}{!rows.length?<div className="empty-state">{empty}</div>:null}</>;
}

export function CaptainGeneral({journeys,todayAllocationIds,now,onOpenToday,onRetry,loading=false,error=''}:{journeys:readonly CaptainJourney[];todayAllocationIds:ReadonlySet<string>;now:Date;onOpenToday:()=>void;onRetry:()=>void;loading?:boolean;error?:string}){
 if(loading)return <div className="captain-general"><div className="empty-state" role="status">Loading General journey boundaries…</div></div>;
 if(error)return <div className="captain-general"><div className="action-error" role="alert"><p>General cannot be separated from Today: {error}</p><button type="button" className="btn secondary" onClick={onRetry}>Retry General</button></div></div>;
 const today=journeys.filter(journey=>todayAllocationIds.has(allocationId(journey)));
 const remaining=journeys.filter(journey=>!todayAllocationIds.has(allocationId(journey)));
 const possible=remaining.filter(journey=>!confirmed(journey)&&!completed(journey));
 const future=remaining.filter(journey=>confirmed(journey)&&!completed(journey)&&(scheduledTime(journey)??Number.NEGATIVE_INFINITY)>now.getTime());
 const history=remaining.filter(completed);
 const review=remaining.filter(journey=>!possible.includes(journey)&&!future.includes(journey)&&!history.includes(journey));
 return <div className="captain-general">
  {today.length?<Section title="Operating today"><JourneyRows rows={today} empty="" today onOpenToday={onOpenToday}/></Section>:null}
  <Section title="Possible journeys"><JourneyRows rows={possible} empty="No possible journeys are currently available."/></Section>
  <Section title="Confirmed future journeys"><JourneyRows rows={future} empty="No future journeys are currently confirmed."/></Section>
  <Section title="Completed journeys and history"><JourneyRows rows={history} empty="No completed journeys are linked to this account yet."/></Section>
  {review.length?<Section title="Past journeys needing review"><JourneyRows rows={review} empty=""/></Section>:null}
  <Section title="Captain operating guidance"><div className="grid-3"><div className="mini-metric"><small>Before departure</small><strong>Review Today</strong><p className="data-note">Check the assigned vehicle, scheduled time and passenger list before starting.</p></div><div className="mini-metric"><small>During disruption</small><strong>Keep parties informed</strong><p className="data-note">Use the protected communications for the duty operating today.</p></div><div className="mini-metric"><small>After arrival</small><strong>Preserve evidence</strong><p className="data-note">Actual times and completion notes remain part of the operational audit.</p></div></div></Section>
 </div>;
}
