'use client';
import React, { useMemo, useState } from 'react';
import { formatServiceSchedule } from '@/lib/operator-vehicle-editor';
import { Status } from './ui';

type Vehicle={
 id:string; operator_id:string; vehicle_type_id:string; name:string;
 default_min_seats:number; default_max_seats:number; default_min_revenue_cents:number;
 default_min_value_threshold_ratio:number|null;
};

type EligibleService={
 operator_id:string; vehicle_type_id:string; route_id:string; route_name:string; service_id:string;
 days_of_week:number[]; departure_time:string; timezone:string;
};

type Assignment={
 offer_id:string; operator_id:string; vehicle_id:string; route_name:string; service_id:string;
 service_days_of_week:number[]; service_departure_time:string; service_timezone:string;
 active:boolean; min_seats:number; max_seats:number; min_revenue_cents:number;
};

const money=(c:number)=>new Intl.NumberFormat('en-US',{style:'currency',currency:'USD',maximumFractionDigits:0}).format((c||0)/100);

export function AdminServiceAssignment({operatorId,vehicles,services,assignments,onAssign}:{
 operatorId:string;
 vehicles:Vehicle[];
 services:EligibleService[];
 assignments:Assignment[];
 onAssign:(vehicle:Vehicle,service:EligibleService)=>void|Promise<void>;
}){
 const [vehicleId,setVehicleId]=useState('');
 const [serviceId,setServiceId]=useState('');
 const vehicle=vehicles.find(candidate=>candidate.id===vehicleId);
 const eligibleServices=useMemo(()=>services.filter(service=>
  service.operator_id===operatorId&&service.vehicle_type_id===vehicle?.vehicle_type_id
 ),[operatorId,services,vehicle?.vehicle_type_id]);
 const service=eligibleServices.find(candidate=>candidate.service_id===serviceId);

 return <>
  <div className="admin-action-row">
   <label className="form-field"><span>Vehicle</span><select aria-label="Assignment vehicle" value={vehicleId} onChange={event=>{setVehicleId(event.target.value);setServiceId('')}}><option value="">Select vehicle</option>{vehicles.map(candidate=><option key={candidate.id} value={candidate.id}>{candidate.name}</option>)}</select></label>
   <label className="form-field"><span>Scheduled service</span><select aria-label="Scheduled service" disabled={!vehicle} value={serviceId} onChange={event=>setServiceId(event.target.value)}><option value="">Select scheduled service</option>{eligibleServices.map(candidate=><option key={candidate.service_id} value={candidate.service_id}>{candidate.route_name} — {formatServiceSchedule(candidate.days_of_week,candidate.departure_time)}</option>)}</select></label>
   <button className="btn secondary" disabled={!vehicle||!service} onClick={()=>{if(vehicle&&service)void onAssign(vehicle,service)}}>+ Assign Service</button>
  </div>
  {assignments.map(assignment=>{
   const assignedVehicle=vehicles.find(candidate=>candidate.id===assignment.vehicle_id);
   return <div className="notice" key={assignment.offer_id}><span><b>{assignedVehicle?.name||'Vehicle'}</b><br/><small>{assignment.route_name} — {formatServiceSchedule(assignment.service_days_of_week,assignment.service_departure_time)} · {assignment.min_seats}–{assignment.max_seats} seats · {money(assignment.min_revenue_cents)} min</small></span><Status value={assignment.active?'ACTIVE':'INACTIVE'}/></div>;
  })}
  {!assignments.length&&<div className="empty-state">No service assignments.</div>}
 </>;
}
