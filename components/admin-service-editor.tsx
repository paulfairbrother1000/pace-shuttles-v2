'use client';
import React,{useEffect,useRef,useState} from 'react';
import {
 adminLoadPairedJourneyDesign,
 adminLoadRouteReturnMappingOptions,
 adminSaveServiceSchedule,
 adminGenerateDepartures,
 adminSavePairedJourneyDesign,
 adminSaveRouteReturnMapping
} from '@/lib/data';

type ReturnRoute={id:string;route_name?:string;name?:string;is_active?:boolean};
type MappingOptions={
 outbound_route_id?:string;
 outbound_route_name?:string;
 mapped_return_route_id?:string|null;
 eligible_return_routes?:ReturnRoute[];
};
type AdminServiceEditorProps={
 serviceId:string;
 daysOfWeek?:number[];
 validFrom?:string|null;
 validTo?:string|null;
 recurrenceType?:string;
 recurrenceIntervalWeeks?:number;
 recurrenceAnchorDate?:string|null;
 onSaved?:()=>void;
 outboundLocalTime:string|null|undefined;
 returnEnabled?:boolean;
 returnLocalTime?:string|null;
 returnDurationMinutes?:number|null;
 returnRouteId?:string|null;
 returnRoutes?:ReturnRoute[];
};
type Result={data:unknown;error:unknown};

const EMPTY_RETURN_ROUTES:ReturnRoute[]=[];
const asTime=(value:string|null|undefined)=>String(value||'').slice(0,5);
const errorText=(error:unknown)=>error instanceof Error?error.message:(error as {message?:string}|null)?.message||String(error);
const firstRow=<T,>(data:unknown):T|undefined=>(Array.isArray(data)?data[0]:data) as T|undefined;
const activeRoutes=(routes:unknown,fallback:ReturnRoute[]=EMPTY_RETURN_ROUTES)=>{
 const rows=Array.isArray(routes)?routes:fallback;
 return [...rows].filter((route):route is ReturnRoute=>Boolean(route&&typeof route==='object'&&(route as ReturnRoute).id)&&(route as ReturnRoute).is_active!==false)
  .sort((left,right)=>(left.route_name||left.name||left.id).localeCompare(right.route_name||right.name||right.id)||left.id.localeCompare(right.id));
};

const WEEKDAYS=[['Sun',0],['Mon',1],['Tue',2],['Wed',3],['Thu',4],['Fri',5],['Sat',6]] as const;
const DEFAULT_DAYS:number[]=[];
export function AdminServiceEditor({serviceId,daysOfWeek=DEFAULT_DAYS,validFrom='',validTo='',recurrenceType='weekly',recurrenceIntervalWeeks=1,recurrenceAnchorDate,onSaved,outboundLocalTime,returnEnabled=false,returnLocalTime,returnDurationMinutes,returnRouteId,returnRoutes=EMPTY_RETURN_ROUTES}:AdminServiceEditorProps){
 const [outboundTime,setOutboundTime]=useState(asTime(outboundLocalTime));
 const [serviceDays,setServiceDays]=useState<number[]>(daysOfWeek);
 const [seasonFrom,setSeasonFrom]=useState(String(validFrom||''));
 const [seasonTo,setSeasonTo]=useState(String(validTo||''));
 const [hasReturn,setHasReturn]=useState(returnEnabled);
 const [returnTime,setReturnTime]=useState(asTime(returnLocalTime));
 const [returnDuration,setReturnDuration]=useState(returnDurationMinutes==null?'':String(returnDurationMinutes));
 const [reverseRouteId,setReverseRouteId]=useState(returnRouteId||'');
 const [eligibleRoutes,setEligibleRoutes]=useState<ReturnRoute[]>(()=>activeRoutes(returnRoutes));
 const [outboundRouteId,setOutboundRouteId]=useState('');
 const [outboundRouteName,setOutboundRouteName]=useState('');
 const [mappedRouteId,setMappedRouteId]=useState('');
 const [mappingRoutes,setMappingRoutes]=useState<ReturnRoute[]>([]);
 const [message,setMessage]=useState<{kind:'success'|'error';text:string}|null>(null);
 const [saving,setSaving]=useState(false);
 const [mappingSaving,setMappingSaving]=useState(false);
 const [hydrating,setHydrating]=useState(true);
 const [loadFailed,setLoadFailed]=useState(false);
 const [loadAttempt,setLoadAttempt]=useState(0);
 const generation=useRef(0);

 const applyResults=(designResult:Result,mappingResult:Result)=>{
  if(designResult.error)throw designResult.error;
  if(mappingResult.error)throw mappingResult.error;
  const design=firstRow<Record<string,unknown>>(designResult.data);
  const mapping=firstRow<MappingOptions>(mappingResult.data);
  if(design){
   setEligibleRoutes(activeRoutes(design.eligible_return_routes));
   setOutboundTime(asTime(design.outbound_local_time as string|null));
   setHasReturn(Boolean(design.return_enabled));
   setReturnTime(asTime(design.return_local_time as string|null));
   setReturnDuration(design.return_duration_minutes==null?'':String(design.return_duration_minutes));
   setReverseRouteId(String(design.reverse_route_id||''));
  }
  setOutboundRouteId(mapping?.outbound_route_id||'');
  setOutboundRouteName(mapping?.outbound_route_name||'');
  setMappedRouteId(mapping?.mapped_return_route_id||'');
  setMappingRoutes(activeRoutes(mapping?.eligible_return_routes));
 };

 useEffect(()=>{
  const request=++generation.current;
  let active=true;
  setOutboundTime(asTime(outboundLocalTime));
  setServiceDays(Array.isArray(daysOfWeek)?daysOfWeek:[]);
  setSeasonFrom(String(validFrom||''));
  setSeasonTo(String(validTo||''));
  setHasReturn(returnEnabled);
  setReturnTime(asTime(returnLocalTime));
  setReturnDuration(returnDurationMinutes==null?'':String(returnDurationMinutes));
  setReverseRouteId(returnRouteId||'');
  setEligibleRoutes(activeRoutes(returnRoutes));
  setOutboundRouteId('');
  setOutboundRouteName('');
  setMappedRouteId('');
  setMappingRoutes([]);
  setMessage(null);
  setSaving(false);
  setMappingSaving(false);
  setHydrating(true);
  setLoadFailed(false);
  void Promise.all([
   adminLoadPairedJourneyDesign(serviceId),
   adminLoadRouteReturnMappingOptions(serviceId)
  ]).then(([designResult,mappingResult])=>{
   if(!active||request!==generation.current)return;
   applyResults(designResult,mappingResult);
   setLoadFailed(false);
  }).catch(error=>{
   if(active&&request===generation.current){setMessage({kind:'error',text:errorText(error)});setLoadFailed(true)}
  }).finally(()=>{if(active&&request===generation.current)setHydrating(false)});
  return()=>{active=false};
 },[serviceId,outboundLocalTime,returnEnabled,returnLocalTime,returnDurationMinutes,returnRouteId,returnRoutes,daysOfWeek,validFrom,validTo,loadAttempt]);

 const saveDesign=async()=>{
  const request=generation.current;
  setMessage(null);
  const duration=returnDuration.trim()===''?null:Number(returnDuration);
  if(!outboundTime){setMessage({kind:'error',text:'Outbound departure time is required.'});return}
  if(hasReturn&&!reverseRouteId){setMessage({kind:'error',text:'Choose an eligible return route.'});return}
  if(hasReturn&&!eligibleRoutes.some(route=>route.id===reverseRouteId)){setMessage({kind:'error',text:'Choose an eligible return route.'});return}
  if(hasReturn&&!returnTime){setMessage({kind:'error',text:'Return pickup time at destination is required.'});return}
  if(hasReturn&&duration===null){setMessage({kind:'error',text:'Return duration is required.'});return}
  if(hasReturn&&duration!==null&&(!Number.isInteger(duration)||duration<=0)){setMessage({kind:'error',text:'Return duration must be a positive whole number of minutes.'});return}
  if(serviceDays.length===0){setMessage({kind:'error',text:'Choose at least one operating day.'});return}
  if(!seasonFrom){setMessage({kind:'error',text:'Season start date is required.'});return}
  if(seasonTo&&seasonTo<seasonFrom){setMessage({kind:'error',text:'Season end date must be on or after the start date.'});return}
  setSaving(true);
  try{
   const schedule=await adminSaveServiceSchedule({p_service_id:serviceId,p_days_of_week:serviceDays,p_departure_time:outboundTime,p_valid_from:seasonFrom,p_valid_to:seasonTo||null,p_recurrence_type:recurrenceType,p_recurrence_interval_weeks:recurrenceIntervalWeeks,p_recurrence_anchor_date:recurrenceAnchorDate||seasonFrom});
   if(schedule.error){setMessage({kind:'error',text:errorText(schedule.error)});return}
   const generationFrom=seasonFrom>new Date().toISOString().slice(0,10)?seasonFrom:new Date().toISOString().slice(0,10);
   if(seasonTo&&seasonTo>=generationFrom){
    const generated=await adminGenerateDepartures(generationFrom,seasonTo);
    if(generated.error){setMessage({kind:'error',text:`Schedule saved, but departures could not be generated: ${errorText(generated.error)}`});return}
   }
   const result=await adminSavePairedJourneyDesign({serviceId,outboundLocalTime:outboundTime,returnEnabled:hasReturn,returnLocalTime:hasReturn?returnTime:null,returnDurationMinutes:hasReturn?duration:null,reverseRouteId:hasReturn?reverseRouteId:null});
   if(request!==generation.current)return;
   if(result.error){setMessage({kind:'error',text:`Schedule saved, but journey details could not be saved: ${errorText(result.error)}`});return}
   setMessage({kind:'success',text:'Schedule and journey details saved.'});
   onSaved?.();
  }catch(error){if(request===generation.current)setMessage({kind:'error',text:errorText(error)})}
  finally{if(request===generation.current)setSaving(false)}
 };

 const saveMapping=async()=>{
  const request=generation.current;
  if(mappingSaving||saving)return;
  setMessage(null);
  if(!outboundRouteId||!mappedRouteId||!mappingRoutes.some(route=>route.id===mappedRouteId)){
   setMessage({kind:'error',text:'Choose an eligible same-country return route.'});
   return;
  }
  setMappingSaving(true);
  try{
   const saved=await adminSaveRouteReturnMapping({outboundRouteId,returnRouteId:mappedRouteId});
   if(request!==generation.current)return;
   if(saved.error){setMessage({kind:'error',text:errorText(saved.error)});return}
   const [designResult,mappingResult]=await Promise.all([
    adminLoadPairedJourneyDesign(serviceId),
    adminLoadRouteReturnMappingOptions(serviceId)
   ]);
   if(request!==generation.current)return;
   applyResults(designResult,mappingResult);
   setMessage({kind:'success',text:'Return route mapping saved. The refreshed route is ready for the return journey design.'});
  }catch(error){if(request===generation.current)setMessage({kind:'error',text:errorText(error)})}
  finally{if(request===generation.current)setMappingSaving(false)}
 };

 const disabled=hydrating||saving||mappingSaving||loadFailed;
 const mappingDisabled=disabled||hasReturn||!outboundRouteId;
 return <form className="form-grid" noValidate onSubmit={event=>{event.preventDefault();void saveDesign()}}>
  <fieldset className="form-grid" disabled={hydrating||saving||mappingSaving||loadFailed}>
   <legend>Return route mapping</legend>
   <p className="data-note">{outboundRouteName?outboundRouteName+': ':''}Choose an active route in the same country. Disable and save the return journey before changing its route mapping.</p>
   <label className="form-field"><span>Mapped return route</span><select aria-label="Mapped return route" disabled={mappingDisabled} value={mappedRouteId} onChange={event=>{setMappedRouteId(event.target.value);setMessage(null)}}><option value="">Select an eligible same-country route</option>{mappingRoutes.map(route=><option key={route.id} value={route.id}>{route.route_name||route.name||route.id}</option>)}</select></label>
   <div className="action-buttons"><button className="btn secondary" type="button" disabled={mappingDisabled||!mappedRouteId} onClick={()=>{void saveMapping()}}>{mappingSaving?'Saving route mapping…':'Save return route mapping'}</button></div>
  </fieldset>
  <fieldset className="form-grid" disabled={disabled}>
   <legend>Weekly schedule and season</legend>
   <div className="form-field"><span>Operating days</span><div className="check-list" role="group" aria-label="Operating days">{WEEKDAYS.map(([label,day])=><label className={serviceDays.includes(day)?'check-row checked':'check-row'} key={day}><input type="checkbox" checked={serviceDays.includes(day)} onChange={event=>setServiceDays(current=>event.target.checked?[...new Set([...current,day])].sort((a,b)=>a-b):current.filter(value=>value!==day))}/><span>{label}</span></label>)}</div></div>
   <label className="form-field"><span>Outbound departure time</span><input aria-label="Outbound departure time" type="time" required value={outboundTime} onChange={event=>setOutboundTime(event.target.value)}/></label>
   <label className="form-field"><span>Season starts</span><input aria-label="Season starts" type="date" required value={seasonFrom} onChange={event=>setSeasonFrom(event.target.value)}/></label>
   <label className="form-field"><span>Season ends</span><input aria-label="Season ends" type="date" value={seasonTo} onChange={event=>setSeasonTo(event.target.value)}/></label>
  </fieldset>
  <label className="form-field"><span>Return journey</span><input aria-label="Return journey" type="checkbox" disabled={disabled} checked={hasReturn} onChange={event=>setHasReturn(event.target.checked)}/></label>
  <label className="form-field"><span>Return route</span><select aria-label="Return route" disabled={!hasReturn||disabled} value={reverseRouteId} onChange={event=>setReverseRouteId(event.target.value)}><option value="">Select the mapped operational return route</option>{eligibleRoutes.map(route=><option key={route.id} value={route.id}>{route.route_name||route.name||route.id}</option>)}</select></label>
  <label className="form-field"><span>Return pickup time at destination</span><input aria-label="Return pickup time at destination" type="time" disabled={!hasReturn||disabled} required={hasReturn} value={returnTime} onChange={event=>setReturnTime(event.target.value)}/></label>
  <label className="form-field"><span>Return duration (minutes)</span><input aria-label="Return duration (minutes)" type="number" min="1" step="1" disabled={!hasReturn||disabled} required={hasReturn} value={returnDuration} onChange={event=>setReturnDuration(event.target.value)}/></label>
  <div className="action-buttons"><button className="btn" type="submit" disabled={disabled}>{hydrating?'Loading journey design…':saving?'Saving schedule & journey…':'Save schedule & journey'}</button>{loadFailed?<button className="btn secondary" type="button" onClick={()=>setLoadAttempt(attempt=>attempt+1)}>Retry loading journey design</button>:null}</div>
  {message?<p className={message.kind==='success'?'action-success':'action-error'} role={message.kind==='success'?'status':'alert'}>{message.text}</p>:null}
 </form>;
}
