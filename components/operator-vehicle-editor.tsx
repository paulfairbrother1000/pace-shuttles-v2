'use client';
import React,{useEffect,useMemo,useState} from 'react';
import {
 blankVehicleDraft,newRouteOffer,toVehicleSavePayload,validateVehicleDraft,vehicleToDraft,
 CaptainOption,RouteOfferDraft,RouteOfferRow,RouteOption,VehicleEditorDraft,VehicleEditorRow,VehicleTypeOption
} from '@/lib/operator-vehicle-editor';

type Props={
 vehicles:VehicleEditorRow[]; offers:RouteOfferRow[]; captains:CaptainOption[]; routes:RouteOption[]; vehicleTypes:VehicleTypeOption[];
 busy:boolean; onSave:(payload:Record<string,unknown>)=>Promise<boolean>; onBlockDates?:(vehicle:VehicleEditorRow)=>void;
};

const fieldError=(errors:Record<string,string>,name:string)=>errors[name]?<small className="field-error">{errors[name]}</small>:null;

export function OperatorVehicleEditor({vehicles,offers,captains,routes,vehicleTypes,busy,onSave,onBlockDates}:Props){
 const [selectedId,setSelectedId]=useState<string|null>(vehicles[0]?.vehicle_id||null);
 const [draft,setDraft]=useState<VehicleEditorDraft>(()=>vehicles[0]?vehicleToDraft(vehicles[0],offers):blankVehicleDraft());
 const [errors,setErrors]=useState<Record<string,string>>({});
 const [routeId,setRouteId]=useState('');

 useEffect(()=>{
  if(selectedId){const vehicle=vehicles.find(v=>v.vehicle_id===selectedId);if(vehicle)setDraft(vehicleToDraft(vehicle,offers));}
 },[vehicles,offers,selectedId]);

 const selectVehicle=(id:string)=>{const vehicle=vehicles.find(v=>v.vehicle_id===id);if(!vehicle)return;setSelectedId(id);setDraft(vehicleToDraft(vehicle,offers));setErrors({});setRouteId('');};
 const addVehicle=()=>{const next=blankVehicleDraft();next.operatorId=vehicleTypes[0]?.operator_id||null;setSelectedId(null);setDraft(next);setErrors({});setRouteId('');};
 const update=<K extends keyof VehicleEditorDraft,>(name:K,value:VehicleEditorDraft[K])=>setDraft(current=>({...current,[name]:value}));
 const updateOffer=(index:number,patch:Partial<RouteOfferDraft>)=>setDraft(current=>({...current,routeOffers:current.routeOffers.map((offer,i)=>i===index?{...offer,...patch}:offer)}));
 const selectedVehicle=vehicles.find(v=>v.vehicle_id===selectedId);
 const captainOptions=useMemo(()=>captains.filter(c=>c.operator_id===draft.operatorId&&c.vehicle_type_id===draft.vehicleTypeId),[captains,draft.operatorId,draft.vehicleTypeId]);
 const typeOptions=useMemo(()=>{
  const seen=new Set<string>();return vehicleTypes.filter(t=>(!draft.operatorId||t.operator_id===draft.operatorId)&&!seen.has(t.vehicle_type_id)&&!!seen.add(t.vehicle_type_id));
 },[vehicleTypes,draft.operatorId]);
 const attached=new Set(draft.routeOffers.filter(o=>!o.remove).map(o=>o.routeId));
 const routeOptions=routes.filter(r=>r.operator_id===draft.operatorId&&r.vehicle_type_id===draft.vehicleTypeId&&!attached.has(r.route_id));
 const addRoute=()=>{const route=routeOptions.find(r=>r.route_id===routeId);if(!route)return;setDraft(current=>({...current,routeOffers:[...current.routeOffers,newRouteOffer(route,current.capacitySeats)]}));setRouteId('');};
 const cancel=()=>selectedVehicle?selectVehicle(selectedVehicle.vehicle_id):addVehicle();
 const save=async()=>{const nextErrors=validateVehicleDraft(draft);setErrors(nextErrors);if(Object.keys(nextErrors).length)return;const ok=await onSave(toVehicleSavePayload(draft));if(ok)setErrors({});};

 return <section className="vehicle-workspace" aria-label="Fleet and vehicle editor">
  <aside className="fleet-rail">
   <div className="fleet-rail-head"><div><small>Your fleet</small><strong>{vehicles.length} vehicles</strong></div><button className="btn" onClick={addVehicle}>+ Add vehicle</button></div>
   <div className="fleet-list">{vehicles.map(vehicle=><button key={vehicle.vehicle_id} className={`fleet-item ${selectedId===vehicle.vehicle_id?'selected':''}`} onClick={()=>selectVehicle(vehicle.vehicle_id)}>
    <span><b>{vehicle.name}</b><small>{vehicle.vehicle_type_name} · {vehicle.capacity_seats} seats</small><small>Default captain: {vehicle.preferred_captain_name||'Not set'}</small></span><em>{vehicle.active?'Active':'Inactive'}</em>
   </button>)}{!vehicles.length&&<div className="empty-state">No vehicles yet. Add your first vehicle.</div>}</div>
  </aside>

  <div className="vehicle-editor">
   <header className="vehicle-editor-head"><div><h2>{draft.vehicleId?draft.name||'Vehicle details':'New vehicle'}</h2><p>Vehicle profile and route participation</p></div><span className={`status ${draft.active?'active':'cancelled'}`}>{draft.active?'ACTIVE':'INACTIVE'}</span></header>
   <div className="editor-panel"><h3>Vehicle details</h3><div className="vehicle-form-grid">
    <label><span>Vehicle name</span><input value={draft.name} onChange={e=>update('name',e.target.value)} />{fieldError(errors,'name')}</label>
    <label><span>Transport Type</span><select value={draft.vehicleTypeId} onChange={e=>{update('vehicleTypeId',e.target.value);update('preferredCaptainId','')}}><option value="">Select Transport Type</option>{typeOptions.map(t=><option key={t.vehicle_type_id} value={t.vehicle_type_id}>{t.vehicle_type_name}</option>)}</select>{fieldError(errors,'vehicleTypeId')}</label>
    <label><span>Passenger capacity</span><input type="number" min="1" step="1" value={draft.capacitySeats} onChange={e=>update('capacitySeats',e.target.value)}/>{fieldError(errors,'capacitySeats')}</label>
    <label><span>Default / preferred captain</span><select value={draft.preferredCaptainId} onChange={e=>update('preferredCaptainId',e.target.value)} disabled={!draft.vehicleTypeId}><option value="">No preferred captain</option>{captainOptions.map(c=><option key={c.captain_id} value={c.captain_id}>{c.captain_name}</option>)}</select></label>
    <label className="wide-field"><span>Description</span><textarea value={draft.description} onChange={e=>update('description',e.target.value)} /></label>
    <label className="wide-field"><span>Vehicle image URL</span><input type="url" value={draft.pictureUrl} onChange={e=>update('pictureUrl',e.target.value)} placeholder="https://…"/></label>
   </div></div>

   <div className="editor-panel route-offers-panel"><div className="route-panel-head"><div><h3>Routes &amp; pricing</h3><p>Add this vehicle to eligible routes and set the commercial terms for each complete two-leg journey.</p></div></div>
    <div className="add-route-row"><label><span>Add route</span><select aria-label="Eligible route" value={routeId} onChange={e=>setRouteId(e.target.value)} disabled={!draft.vehicleTypeId}><option value="">{draft.vehicleTypeId?'Select an eligible route':'Select Transport Type first'}</option>{routeOptions.map(route=><option key={route.route_id} value={route.route_id}>{route.route_name}</option>)}</select></label><button className="btn secondary" disabled={!routeId} onClick={addRoute}>+ Add route</button></div>
    <div className="offer-list">{draft.routeOffers.map((offer,index)=><RouteOfferCard key={offer.key} offer={offer} index={index} errors={errors} captains={captainOptions} defaultCaptainName={captainOptions.find(c=>c.captain_id===draft.preferredCaptainId)?.captain_name||''} update={patch=>updateOffer(index,patch)}/>)}</div>
    {!draft.routeOffers.some(o=>!o.remove)&&<div className="empty-state">This vehicle is not attached to any routes yet.</div>}
   </div>

   <footer className="vehicle-editor-actions"><div>{draft.vehicleId&&<><button className="link-danger" onClick={()=>update('active',!draft.active)}>{draft.active?'Deactivate vehicle':'Reactivate vehicle'}</button>{onBlockDates&&selectedVehicle&&<button className="btn secondary" onClick={()=>onBlockDates(selectedVehicle)}>Block dates</button>}</>}</div><div><button className="btn secondary" disabled={busy} onClick={cancel}>Cancel</button><button className="btn" disabled={busy} onClick={save}>{busy?'Saving…':'Save changes'}</button></div></footer>
  </div>
 </section>;
}

function RouteOfferCard({offer,index,errors,captains,defaultCaptainName,update}:{offer:RouteOfferDraft;index:number;errors:Record<string,string>;captains:CaptainOption[];defaultCaptainName:string;update:(patch:Partial<RouteOfferDraft>)=>void}){
 const prefix=`routeOffers.${index}`;
 const overrideCaptainName=captains.find(c=>c.captain_id===offer.preferredCaptainId)?.captain_name;
 if(offer.remove)return <article className="offer-card removed"><div><b>{offer.routeName}</b><small>Will be removed when you save.</small></div><button className="btn secondary" onClick={()=>update({remove:false})}>Undo</button></article>;
 return <article className="offer-card"><header><div><h4>{offer.routeName}</h4><small>Active Route Offer</small></div><button className="remove-route" onClick={()=>update({remove:true})}>Remove</button></header>
  <div className="offer-grid">
   <label className="route-captain-field"><span>Preferred captain</span><select aria-label={`Preferred captain for ${offer.routeName}`} value={offer.preferredCaptainId} onChange={e=>update({preferredCaptainId:e.target.value})}><option value="">{defaultCaptainName?`Boat default — ${defaultCaptainName}`:'No boat default set'}</option>{captains.map(c=><option key={c.captain_id} value={c.captain_id}>{c.captain_name}</option>)}</select><small className="captain-source">{overrideCaptainName?`Route override — ${overrideCaptainName}`:defaultCaptainName?`Boat default — ${defaultCaptainName}`:'No captain preference set'}</small></label>
   <label><span>Minimum seats</span><input type="number" min="1" step="1" value={offer.minSeats} onChange={e=>update({minSeats:e.target.value})}/>{fieldError(errors,`${prefix}.minSeats`)}</label>
   <label><span>Maximum seats</span><input type="number" min="1" step="1" value={offer.maxSeats} onChange={e=>update({maxSeats:e.target.value})}/>{fieldError(errors,`${prefix}.maxSeats`)}</label>
   <label><span>Minimum journey revenue</span><div className="money-input"><span>$</span><input type="number" min="0" step="1" value={offer.minRevenueUsd} onChange={e=>update({minRevenueUsd:e.target.value})}/></div>{fieldError(errors,`${prefix}.minRevenueUsd`)}</label>
   <label><span>Discount after minimum?</span><select value={offer.discountEnabled?'yes':'no'} onChange={e=>update({discountEnabled:e.target.value==='yes'})}><option value="no">No</option><option value="yes">Yes</option></select></label>
   <label><span>Maximum discount</span><div className="percent-input"><input type="number" min="0" max="100" step="0.1" value={offer.discountPercent} disabled={!offer.discountEnabled} onChange={e=>update({discountPercent:e.target.value})}/><span>%</span></div>{fieldError(errors,`${prefix}.discountPercent`)}</label>
   <label className="below-min-field"><span>If minimum revenue is not met</span><select value={offer.belowMinimumMode} onChange={e=>update({belowMinimumMode:e.target.value as any,thresholdPercent:e.target.value==='custom_threshold'?offer.thresholdPercent:''})}><option value="never">Do not operate</option><option value="route_default">Use route default threshold</option><option value="custom_threshold">Operate at a custom threshold</option></select></label>
   <label><span>Operate from</span><div className="percent-input"><input type="number" min="0.1" max="100" step="0.1" value={offer.thresholdPercent} disabled={offer.belowMinimumMode!=='custom_threshold'} onChange={e=>update({thresholdPercent:e.target.value})}/><span>%</span></div>{fieldError(errors,`${prefix}.thresholdPercent`)}</label>
  </div>
 </article>;
}
