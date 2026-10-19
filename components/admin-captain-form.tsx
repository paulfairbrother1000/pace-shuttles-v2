'use client';

import React,{useEffect,useState} from 'react';
import {adminSaveCaptain} from '@/lib/data';

type CaptainFormProps={
 open:boolean;
 operatorId:string;
 captain?:any;
 vehicleTypes:any[];
 onClose:()=>void;
 onSaved:()=>void;
};

const initial={first_name:'',last_name:'',email:'',phone:'',notes:'',active:true,operator_vetting_confirmed:false,vehicle_type_ids:[] as string[]};

function Field({label,children,hint}:{label:string;children:any;hint?:string}){
 return <label className="form-field"><span>{label}</span>{children}{hint&&<small>{hint}</small>}</label>;
}

export function AdminCaptainForm({open,operatorId,captain,vehicleTypes,onClose,onSaved}:CaptainFormProps){
 const [form,setForm]=useState<any>(initial),[busy,setBusy]=useState(false),[error,setError]=useState('');
 useEffect(()=>{
  if(!open)return;
  setForm({...initial,...captain,vehicle_type_ids:Array.isArray(captain?.vehicle_type_ids)?captain.vehicle_type_ids:[]});
  setError('');
 },[open,captain]);
 const set=(name:string,value:any)=>setForm((x:any)=>({...x,[name]:value}));
 const toggleType=(id:string)=>set('vehicle_type_ids',form.vehicle_type_ids.includes(id)?form.vehicle_type_ids.filter((x:string)=>x!==id):[...form.vehicle_type_ids,id]);
 const save=async(e:any)=>{
  e.preventDefault();
  if(!String(form.first_name||'').trim()||!String(form.last_name||'').trim())return setError('Enter the captain’s first and last name.');
  if(form.active&&!form.vehicle_type_ids.length)return setError('Select at least one transport type for an active captain.');
  if(form.active&&!form.operator_vetting_confirmed)return setError('Record the operator’s vetting and licence confirmation before activating this captain.');
  setBusy(true);setError('');
  const result=await adminSaveCaptain({
   p_captain_id:captain?.id||null,
   p_operator_id:operatorId,
   p_first_name:String(form.first_name).trim(),
   p_last_name:String(form.last_name).trim(),
   p_email:String(form.email||'').trim()||null,
   p_phone:String(form.phone||'').trim()||null,
   p_notes:String(form.notes||'').trim()||null,
   p_active:!!form.active,
   p_operator_vetting_confirmed:!!form.operator_vetting_confirmed,
   p_vehicle_type_ids:form.vehicle_type_ids,
  });
  setBusy(false);
  if(result.error){setError(result.error.message||'Captain could not be saved.');return;}
  onSaved();
 };
 if(!open)return null;
 return <div className="modal-backdrop" role="presentation" onMouseDown={e=>{if(e.currentTarget===e.target&&!busy)onClose()}}>
  <form className="modal-card captain-form-modal" role="dialog" aria-modal="true" aria-label={captain?'Edit captain':'Add captain'} onSubmit={save}>
   <div className="modal-head"><div><h2>{captain?'Edit captain':'Add captain'}</h2><p>Enter captain details, approved transport types and the operator’s confirmation.</p></div><button type="button" className="modal-close" disabled={busy} onClick={onClose} aria-label="Close">×</button></div>
   <div className="modal-body"><div className="form-grid two-col">
    <Field label="First name"><input autoComplete="given-name" value={form.first_name||''} onChange={e=>set('first_name',e.target.value)}/></Field>
    <Field label="Last name"><input autoComplete="family-name" value={form.last_name||''} onChange={e=>set('last_name',e.target.value)}/></Field>
    <Field label="Email"><input type="email" autoComplete="email" value={form.email||''} onChange={e=>set('email',e.target.value)}/></Field>
    <Field label="Telephone"><input type="tel" autoComplete="tel" value={form.phone||''} onChange={e=>set('phone',e.target.value)}/></Field>
    <Field label="Comments" hint="Record relevant qualifications, checks or operator comments."><textarea value={form.notes||''} onChange={e=>set('notes',e.target.value)} rows={3}/></Field>
    <fieldset className="form-field full-width transport-type-selector"><legend>Qualified transport types</legend><small>Select the vehicle types this captain is qualified and approved to operate.</small><div className="checkbox-grid">{vehicleTypes.filter((x:any)=>x.active).map((type:any)=><label className="check-row" key={type.id}><input type="checkbox" checked={form.vehicle_type_ids.includes(type.id)} onChange={()=>toggleType(type.id)}/><span><b>{type.name}</b></span></label>)}</div></fieldset>
    <label className="check-row full-width"><input type="checkbox" checked={!!form.operator_vetting_confirmed} onChange={e=>set('operator_vetting_confirmed',e.target.checked)}/><span><b>Operator confirmation</b><small>The operator confirms this captain has been vetted and holds the required licence(s) for the selected transport types.</small></span></label>
    <label className="check-row full-width"><input type="checkbox" checked={!!form.active} onChange={e=>set('active',e.target.checked)}/><span><b>Active captain</b><small>Active captains can be assigned to eligible journeys.</small></span></label>
   </div>{error&&<p className="action-error" role="alert">{error}</p>}</div>
   <div className="modal-footer"><button type="button" className="btn secondary" disabled={busy} onClick={onClose}>Cancel</button><button type="submit" className="btn" disabled={busy}>{busy?'Saving…':captain?'Save captain':'Add captain'}</button></div>
  </form>
 </div>;
}
