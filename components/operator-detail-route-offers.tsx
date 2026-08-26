'use client';

import {useEffect,useState} from 'react';
import {
  loadOperators,loadVehicles,loadCaptains,loadVehicleRouteOffers,
  loadVehicleUnavailability,loadOperatorCommissionOverrides,loadCountryCommissions,loadCancellationPolicies,
  adminCreateCaptain,adminUpdateOperator,adminSetOperatorCommissionOverride,adminEndOperatorCommissionOverride
} from '@/lib/data';
import {KpiCard,Section,Status} from './ui';
import {AdminOperatorVehicleEditor} from './admin-operator-vehicle-editor';

const date=(x:any)=>x?new Date(x).toLocaleString():'—';

function useLoad(fn:any){
  const [rows,setRows]=useState<any[]>([]),[error,setError]=useState('');
  useEffect(()=>{void fn().then((r:any)=>{setRows(r.data||[]);setError(r.error?.message||'')})},[]);
  return {rows,error};
}

export function OperatorDetailRouteOffers({id}:{id:string}){
  const {rows:operators,error:operatorError}=useLoad(loadOperators);
  const {rows:vehicles}=useLoad(loadVehicles);
  const {rows:captains}=useLoad(loadCaptains);
  const {rows:offers}=useLoad(loadVehicleRouteOffers);
  const {rows:unavailability}=useLoad(loadVehicleUnavailability);
  const {rows:overrides}=useLoad(loadOperatorCommissionOverrides);
  const {rows:countryCommissions}=useLoad(loadCountryCommissions);
  const {rows:policies}=useLoad(loadCancellationPolicies);
  const [msg,setMsg]=useState('');
  const operator=operators.find(x=>x.id===id);
  if(!operator)return <Section title="Operator"><div className="empty-state">{operatorError||'Loading operator…'}</div></Section>;

  const fleet=vehicles.filter(x=>x.operator_id===id);
  const crew=captains.filter(x=>x.operator_id===id);
  const routeOffers=offers.filter(x=>x.operator_id===id);
  const blocks=unavailability.filter(x=>x.operator_id===id);
  const currentOverride=overrides.find(x=>x.operator_id===id&&!x.effective_to);
  const countryCommission=countryCommissions.find(x=>x.country_id===operator.country_id&&!x.effective_to);

  const done=(r:any,label:string)=>{
    if(r.error)setMsg(r.error.message||String(r.error));
    else{setMsg(label+' saved');window.setTimeout(()=>window.location.reload(),450)}
  };

  return <>
    <Section title={operator.name}>
      <div className="grid-4">
        <KpiCard label="Quality" value={String(operator.quality_score??'—')}/>
        <KpiCard label="Vehicles" value={String(fleet.length)}/>
        <KpiCard label="Route offers" value={String(routeOffers.length)}/>
        <KpiCard label="Status" value={operator.active?'Active':'Inactive'}/>
      </div>
    </Section>

    <div className="grid-2" style={{marginTop:12}}>
      <Section title="Commercial settings">
        <div className="notice"><span>Country commission</span><b>{countryCommission?Number(countryCommission.commission_bps/100).toFixed(2)+'%':'—'}</b></div>
        <div className="notice"><span>Operator override</span><b>{currentOverride?Number(currentOverride.commission_bps/100).toFixed(2)+'%':'None'}</b></div>
        <div className="action-buttons"><button className="btn secondary" onClick={async()=>{const raw=window.prompt('Operator commission override %',currentOverride?String(currentOverride.commission_bps/100):'10');if(raw===null)return;const pct=Number(raw);if(!Number.isFinite(pct)||pct<0||pct>100)return setMsg('Enter a percentage from 0 to 100');done(await adminSetOperatorCommissionOverride(id,Math.round(pct*100),'Set by Site Admin'),'Commission override')}}>Set override</button>{currentOverride&&<button className="btn secondary" onClick={async()=>done(await adminEndOperatorCommissionOverride(id),'Country default commission')}>Use country default</button>}</div>
      </Section>
      <Section title="Operator administration">
        <div className="notice"><span>Admin email</span><b>{operator.admin_email||operator.email||'—'}</b></div>
        <div className="notice"><span>Cancellation policy</span><b>{policies.find(p=>p.id===operator.cancellation_policy_id)?.name||'Default / none'}</b></div>
        <button className="btn secondary" onClick={async()=>{const email=window.prompt('Operator admin email',operator.admin_email||operator.email||'')||null;const phone=window.prompt('Phone',operator.phone||'')||null;done(await adminUpdateOperator({p_operator_id:id,p_admin_email:email,p_phone:phone,p_country_id:operator.country_id,p_region_id:operator.region_id,p_locality_id:operator.locality_id,p_town:operator.town,p_region_text:operator.region,p_active:operator.active,p_cancellation_policy_id:operator.cancellation_policy_id}),'Operator contact')}}>Edit contact</button>
      </Section>
    </div>

    <div style={{marginTop:12}}>
      <Section title="Captains" action={<button className="btn secondary" onClick={async()=>{const first=window.prompt('Captain first name');if(!first)return;const last=window.prompt('Captain last name');if(!last)return;done(await adminCreateCaptain({p_operator_id:id,p_first_name:first,p_last_name:last,p_email:null,p_phone:null,p_notes:'Created by Site Admin'}),'Captain')}}>+ Add Captain</button>}>
        {crew.map(c=><div className="notice" key={c.id}><span><b>{c.first_name} {c.last_name}</b></span><Status value={c.active?'ACTIVE':'INACTIVE'}/></div>)}
        {!crew.length&&<div className="empty-state">No captains.</div>}
      </Section>
    </div>

    <Section title="Vehicles & route participation">
      <p className="data-note">Select a vehicle to edit its details, preferred captain, eligible routes, seat limits and complete-journey commercial terms.</p>
      <AdminOperatorVehicleEditor operatorId={id}/>
    </Section>

    <Section title="Vehicle Unavailability">
      {blocks.map(b=><div className="notice" key={b.id}><span><b>{b.vehicle_name}</b><br/><small>{date(b.start_ts)} → {date(b.end_ts)}</small></span><span>{b.reason_code||'Unavailable'}</span></div>)}
      {!blocks.length&&<div className="empty-state">No availability exceptions.</div>}
    </Section>
    {msg&&<p className={msg.toLowerCase().includes('saved')?'action-success':'action-error'}>{msg}</p>}
  </>;
}
