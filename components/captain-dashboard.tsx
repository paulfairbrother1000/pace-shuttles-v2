'use client';
import {useEffect,useMemo,useState} from 'react';
import {
 loadCaptainMyJourneys,loadCaptainManifest,loadCaptainMessages,
 captainStartJourney,captainCompleteJourney,captainSendJourneyMessage
} from '@/lib/data';
import {KpiCard,Section,Status} from './ui';

const when=(x:any)=>x?new Date(x).toLocaleString([],{weekday:'short',day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'}):'—';
const norm=(x:any)=>String(x||'').toLowerCase();

function useRows(fn:any){
 const [rows,setRows]=useState<any[]>([]),[error,setError]=useState('');
 const reload=async()=>{const r=await fn();setRows(r.data||[]);setError(r.error?.message||'')};
 useEffect(()=>{void reload()},[]);
 return {rows,error,reload};
}

export function CaptainDashboard(){
 const journeys=useRows(loadCaptainMyJourneys);
 const manifest=useRows(loadCaptainManifest);
 const messages=useRows(loadCaptainMessages);
 const [selectedId,setSelectedId]=useState(''),[msg,setMsg]=useState(''),[busy,setBusy]=useState(''),[update,setUpdate]=useState(''),[category,setCategory]=useState('late_running');

 const selected=useMemo(()=>{
   if(selectedId)return journeys.rows.find(x=>(x.captain_assignment_id||x.confirmed_allocation_id)===selectedId);
   return journeys.rows.find(x=>x.actual_departure_ts&&!x.actual_arrival_ts)
      || journeys.rows.find(x=>norm(x.departure_status)==='confirmed')
      || journeys.rows[0];
 },[journeys.rows,selectedId]);

 const selectedKey=selected?.captain_assignment_id||selected?.confirmed_allocation_id;
 const pax=selected?manifest.rows.filter(x=>
   x.captain_assignment_id===selected.captain_assignment_id ||
   x.confirmed_allocation_id===selected.confirmed_allocation_id
 ):[];

 const thread=selected?messages.rows.filter(x=>
   x.confirmed_allocation_id===selected.confirmed_allocation_id ||
   x.departure_id===selected.departure_id
 ):[];

 const ready=journeys.rows.filter(x=>!x.actual_departure_ts&&norm(x.departure_status)==='confirmed').length;
 const active=journeys.rows.filter(x=>x.actual_departure_ts&&!x.actual_arrival_ts).length;
 const done=journeys.rows.filter(x=>!!x.actual_arrival_ts||norm(x.departure_status)==='completed').length;

 const refresh=async()=>Promise.all([journeys.reload(),manifest.reload(),messages.reload()]);
 const run=async(name:string,fn:()=>Promise<any>)=>{setBusy(name);setMsg('');const r=await fn();setBusy('');if(r.error)setMsg(r.error.message||String(r.error));else{setMsg(name+' completed');await refresh()}};

 const start=async()=>{
   if(!selected?.captain_assignment_id)return;
   if(window.confirm(`Start ${selected.route_name} now? This records the actual departure time.`))
     await run('Journey start',()=>captainStartJourney(selected.captain_assignment_id));
 };

 const complete=async()=>{
   if(!selected?.captain_assignment_id)return;
   const notes=window.prompt('Voyage / journey notes','')??'';
   const normal=window.confirm('Did the journey complete normally? Choose Cancel for an abnormal completion.');
   let incident=false,summary='';
   if(!normal){incident=true;summary=window.prompt('Incident / abnormal completion summary','')||'Abnormal completion';}
   else if(window.confirm('Was there an incident worth recording?')){incident=true;summary=window.prompt('Incident summary','')||'';}
   if(window.confirm('Complete this journey and record the actual arrival time?'))
     await run('Journey completion',()=>captainCompleteJourney(selected.captain_assignment_id,normal,notes,incident,summary));
 };

 const send=async()=>{
   if(!selected?.confirmed_allocation_id||!update.trim())return;
   await run('Passenger update',()=>captainSendJourneyMessage(selected.confirmed_allocation_id,update.trim(),category));
   setUpdate('');
 };

 return <>
   <div className="grid-4">
     <KpiCard label="Assigned journeys" value={String(journeys.rows.length)}/>
     <KpiCard label="Ready to start" value={String(ready)}/>
     <KpiCard label="In progress" value={String(active)}/>
     <KpiCard label="Completed" value={String(done)}/>
   </div>

   <div className="grid-2" style={{marginTop:12}}>
     <Section title="My journeys">
       {journeys.rows.map(x=>{
         const key=x.captain_assignment_id||x.confirmed_allocation_id;
         const state=x.actual_arrival_ts?'COMPLETED':x.actual_departure_ts?'ACTIVE':String(x.departure_status||'ASSIGNED').toUpperCase();
         return <button className={`support-item ${selectedKey===key?'selected':''}`} key={key} onClick={()=>setSelectedId(key)}>
           <span><b>{x.route_name}</b><small>{when(x.scheduled_departure_ts)} · {x.vehicle_name} · {x.operator_name}</small></span>
           <Status value={state}/>
         </button>
       })}
       {!journeys.rows.length&&<div className="empty-state">No captain journeys are linked to this signed-in account yet.</div>}
     </Section>

     <Section title="Journey control">
       {selected?<>
         <div className="notice"><span><b>{selected.route_name}</b><br/><small>{selected.vehicle_name} · {when(selected.scheduled_departure_ts)}</small></span><Status value={selected.actual_arrival_ts?'COMPLETED':selected.actual_departure_ts?'ACTIVE':String(selected.departure_status||'ASSIGNED').toUpperCase()}/></div>
         <div className="grid-2" style={{marginTop:10}}>
           <div className="mini-metric"><small>Scheduled departure</small><strong>{when(selected.scheduled_departure_ts)}</strong></div>
           <div className="mini-metric"><small>Passengers</small><strong>{pax.length||selected.booked_seats||0}</strong></div>
         </div>
         <div className="action-buttons" style={{marginTop:12}}>
           {!selected.actual_departure_ts&&norm(selected.departure_status)==='confirmed'&&<button className="btn" disabled={!!busy} onClick={start}>Start journey</button>}
           {selected.actual_departure_ts&&!selected.actual_arrival_ts&&<button className="btn" disabled={!!busy} onClick={complete}>Complete journey</button>}
         </div>
         {selected.actual_departure_ts&&<div className="notice" style={{marginTop:12}}><span>Actual departure</span><b>{when(selected.actual_departure_ts)}</b></div>}
         {selected.actual_arrival_ts&&<div className="notice"><span>Actual arrival</span><b>{when(selected.actual_arrival_ts)}</b></div>}
       </>:<div className="empty-state">Select a journey.</div>}
       {msg&&<p className={msg.includes('completed')?'action-success':'action-error'}>{msg}</p>}
     </Section>
   </div>

   <div className="grid-2" style={{marginTop:12}}>
     <Section title="Passenger manifest">
       {pax.map((p:any)=><div className="notice" key={p.passenger_id||`${p.booking_id}-${p.passenger_first_name}`}>
         <span><b>{p.passenger_first_name||p.customer_name} {p.passenger_last_name||''}</b><br/><small>{p.age_group||'Passenger'} · party of {p.booking_party_size||1}</small></span>
         <span><Status value={String(p.booking_status||'BOOKED').toUpperCase()}/><br/><small>{p.special_requirements||p.notes||''}</small></span>
       </div>)}
       {selected&&!pax.length&&<div className="empty-state">No passengers are currently allocated to this journey.</div>}
       {!selected&&<div className="empty-state">Select a journey to view its manifest.</div>}
     </Section>

     <Section title="Passenger updates">
       {selected?<>
         <div className="form-grid">
           <label className="form-field"><span>Update type</span><select value={category} onChange={e=>setCategory(e.target.value)}>
             <option value="late_running">Late running</option>
             <option value="pickup_update">Pickup update</option>
             <option value="weather">Weather / conditions</option>
             <option value="operational">Operational update</option>
           </select></label>
           <label className="form-field"><span>Message to passengers</span><textarea value={update} onChange={e=>setUpdate(e.target.value)} placeholder="e.g. We are running approximately 15 minutes late."/></label>
           <button className="btn" disabled={!update.trim()||!!busy||!selected.confirmed_allocation_id} onClick={send}>Send journey update</button>
         </div>
         <div className="conversation-thread" style={{marginTop:14}}>
           {thread.map((m:any)=><div className={`message ${String(m.sender_type||'captain').toLowerCase()}`} key={m.id}>
             <b>{String(m.sender_type||'captain').replaceAll('_',' ')}</b><p>{m.message_text}</p><small>{when(m.created_at)}</small>
           </div>)}
           {!thread.length&&<div className="empty-state">No journey messages yet.</div>}
         </div>
       </>:<div className="empty-state">Select a journey to send or review passenger updates.</div>}
     </Section>
   </div>

   <Section title="Captain operating rules">
     <div className="grid-3">
       <div className="mini-metric"><small>Before departure</small><strong>Review manifest</strong><p className="data-note">Check the assigned vehicle, scheduled time and passenger list before starting.</p></div>
       <div className="mini-metric"><small>During disruption</small><strong>Message passengers</strong><p className="data-note">Late-running, pickup, weather and operational messages are stored against the journey.</p></div>
       <div className="mini-metric"><small>After arrival</small><strong>Complete journey</strong><p className="data-note">Actual arrival and voyage notes become part of the operational audit and settlement evidence.</p></div>
     </div>
   </Section>

   {(journeys.error||manifest.error||messages.error)&&<p className="action-error">{journeys.error||manifest.error||messages.error}</p>}
 </>;
}
