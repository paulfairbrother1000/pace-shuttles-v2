'use client';

import {useEffect,useState} from 'react';
import {
  loadOperators,loadVehicles,loadCaptains,loadVehicleTypes,loadVehicleRouteOffers,
  loadVehicleUnavailability,loadOperatorCommissionOverrides,loadCountryCommissions,loadCancellationPolicies,
  adminUpdateOperator,adminSetOperatorCommissionOverride,adminEndOperatorCommissionOverride
} from '@/lib/data';
import {KpiCard,Section,Status} from './ui';
import {AdminOperatorVehicleEditor} from './admin-operator-vehicle-editor';
import {AdminOperatorForm} from './admin-operator-form';
import {AdminCaptainForm} from './admin-captain-form';

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
  const {rows:vehicleTypes}=useLoad(loadVehicleTypes);
  const {rows:offers}=useLoad(loadVehicleRouteOffers);
  const {rows:unavailability}=useLoad(loadVehicleUnavailability);
  const {rows:overrides}=useLoad(loadOperatorCommissionOverrides);
  const {rows:countryCommissions}=useLoad(loadCountryCommissions);
  const {rows:policies}=useLoad(loadCancellationPolicies);
  const [msg,setMsg]=useState('');
  const [editing,setEditing]=useState(false);
  const [captainDraft,setCaptainDraft]=useState<any>(null);
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
        <button className="btn secondary" onClick={()=>setEditing(true)}>Edit operator</button>
      </Section>
    </div>

    <div style={{marginTop:12}}>
      <Section title="Captains" action={<button className="btn secondary" onClick={()=>setCaptainDraft({})}>+ Add captain</button>}>
        {crew.map(c=><div className="notice" key={c.id}><span><b>{c.first_name} {c.last_name}</b><br/><small>{(c.vehicle_type_ids||[]).map((typeId:string)=>vehicleTypes.find((t:any)=>t.id===typeId)?.name).filter(Boolean).join(', ')||'No transport types assigned'} · {c.operator_vetting_confirmed?'Vetting and licence confirmed':'Confirmation required'}</small></span><div className="action-buttons"><Status value={c.active?'ACTIVE':'INACTIVE'}/><button className="btn secondary" onClick={()=>setCaptainDraft(c)}>Edit</button></div></div>)}
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
    {msg&&<p className={msg.toLowerCase().includes('saved')?'action-success':'action-error'}>{msg}</p>}<AdminOperatorForm open={editing} operator={operator} onClose={()=>setEditing(false)} onSaved={()=>window.location.reload()}/>
    <AdminCaptainForm key={captainDraft?.id||'new-captain'} open={captainDraft!==null} operatorId={id} captain={captainDraft?.id?captainDraft:undefined} vehicleTypes={vehicleTypes} onClose={()=>setCaptainDraft(null)} onSaved={()=>{setMsg('Captain saved');window.location.reload()}}/>
  </>;
}
