'use client';
import React, {useMemo, useState} from 'react';

export type ServiceRoute = {id:string;route_name?:string|null;name?:string|null;is_active?:boolean;trip_timezone?:string|null};
export type ServiceCreationInput = {
 route:ServiceRoute;name:string;departureTime:string;daysOfWeek:number[];validFrom:string;validTo:string;
 returnEnabled:boolean;returnRouteId:string;returnPickupTime:string;returnDurationMinutes:string;
};

const routeName=(route:ServiceRoute)=>route.route_name||route.name||route.id;
const activeRoutes=(routes:ServiceRoute[])=>routes.filter(route=>route&&route.id&&route.is_active!==false)
 .slice().sort((a,b)=>routeName(a).localeCompare(routeName(b)));

export function AdminServiceCreationForm({routes,onCreate,onCancel,busy=false}:{routes:ServiceRoute[];onCreate:(input:ServiceCreationInput)=>Promise<void>;onCancel:()=>void;busy?:boolean}){
 const choices=useMemo(()=>activeRoutes(routes),[routes]);
 const [routeId,setRouteId]=useState('');
 const [name,setName]=useState('');
 const [departureTime,setDepartureTime]=useState('10:00');
 const [daysOfWeek,setDaysOfWeek]=useState<number[]>([3]);
 const [validFrom,setValidFrom]=useState('2026-11-01');
 const [validTo,setValidTo]=useState('2027-06-30');
 const [returnEnabled,setReturnEnabled]=useState(true);
 const [returnRouteId,setReturnRouteId]=useState('');
 const [returnPickupTime,setReturnPickupTime]=useState('16:00');
 const [returnDurationMinutes,setReturnDurationMinutes]=useState('30');
 const selectedRoute=choices.find(route=>route.id===routeId);
 const reversedRoutes=choices.filter(route=>route.id!==routeId);
 const toggleDay=(day:number)=>setDaysOfWeek(current=>current.includes(day)?current.filter(value=>value!==day):[...current,day].sort((a,b)=>a-b));
 const submit=async(event:React.FormEvent<HTMLFormElement>)=>{
  event.preventDefault();
  if(!selectedRoute||!daysOfWeek.length||!validFrom||!validTo||validTo<validFrom)return;
  if(returnEnabled&&(!returnRouteId||!returnPickupTime||!returnDurationMinutes))return;
  await onCreate({route:selectedRoute,name:name.trim()||`${routeName(selectedRoute)} service`,departureTime,daysOfWeek,validFrom,validTo,returnEnabled,returnRouteId,returnPickupTime,returnDurationMinutes});
 };
 return <form className="form-grid" onSubmit={submit}>
  <label className="form-field"><span>Existing route</span><select aria-label="Existing route" required value={routeId} onChange={event=>{setRouteId(event.target.value);setReturnRouteId('')}}><option value="">Choose an active route…</option>{choices.map(route=><option key={route.id} value={route.id}>{routeName(route)}</option>)}</select></label>
  <label className="form-field"><span>Service name</span><input value={name} onChange={event=>setName(event.target.value)} placeholder={selectedRoute?`${routeName(selectedRoute)} service`:'Route service'}/></label>
  <label className="form-field"><span>Outbound departure time</span><input aria-label="Outbound departure time" type="time" required value={departureTime} onChange={event=>setDepartureTime(event.target.value)}/></label>
  <fieldset className="form-field"><legend>Runs every week</legend><div className="action-buttons">{['Sun','Mon','Tue','Wed','Thu','Fri','Sat'].map((day,index)=><label className="check-row" key={day}><input type="checkbox" checked={daysOfWeek.includes(index)} onChange={()=>toggleDay(index)}/><span>{day}</span></label>)}</div></fieldset>
  <label className="form-field"><span>Season starts</span><input aria-label="Season starts" type="date" required value={validFrom} onChange={event=>setValidFrom(event.target.value)}/></label>
  <label className="form-field"><span>Season ends</span><input aria-label="Season ends" type="date" required min={validFrom} value={validTo} onChange={event=>setValidTo(event.target.value)}/></label>
  <label className="form-field"><span>Return journey</span><span className="check-row"><input aria-label="Return journey" type="checkbox" checked={returnEnabled} onChange={event=>setReturnEnabled(event.target.checked)}/> Include a scheduled return leg</span></label>
  {returnEnabled&&<>
   <label className="form-field"><span>Return route</span><select aria-label="Return route" required value={returnRouteId} onChange={event=>setReturnRouteId(event.target.value)} disabled={!routeId}><option value="">Choose return route…</option>{reversedRoutes.map(route=><option key={route.id} value={route.id}>{routeName(route)}</option>)}</select></label>
   <label className="form-field"><span>Return pickup time at destination</span><input aria-label="Return pickup time at destination" type="time" required value={returnPickupTime} onChange={event=>setReturnPickupTime(event.target.value)}/></label>
   <label className="form-field"><span>Return journey duration (minutes)</span><input aria-label="Return journey duration (minutes)" type="number" min="1" step="1" required value={returnDurationMinutes} onChange={event=>setReturnDurationMinutes(event.target.value)}/></label>
  </>}
  {!choices.length&&<p className="action-error">No active routes are available. Create or activate a route first.</p>}
  <div className="action-buttons"><button className="btn" type="submit" disabled={busy||!choices.length}>Create scheduled journey</button><button className="btn secondary" type="button" onClick={onCancel} disabled={busy}>Cancel</button></div>
 </form>;
}
