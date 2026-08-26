'use client';

import Link from 'next/link';
import {useEffect,useState} from 'react';
import {
  loadOperators,loadVehicles,loadCaptains,loadVehicleTypes,loadRoutes,loadVehicleRouteOffers,
  loadVehicleUnavailability,loadOperatorCommissionOverrides,loadCountryCommissions,loadCancellationPolicies,
  loadRouteVehicleTypes,loadOperatorVehicleTypes,adminCreateVehicle,adminCreateCaptain,adminCreateRouteOffer,
  adminSetRouteOfferActive,adminUpdateOperator,adminSetOperatorCommissionOverride,adminEndOperatorCommissionOverride
} from '@/lib/data';
import {KpiCard,Section,Status} from './ui';

const money=(c:any)=>new Intl.NumberFormat('en-US',{style:'currency',currency:'USD',maximumFractionDigits:0}).format(Number(c||0)/100);
const date=(x:any)=>x?new Date(x).toLocaleString():'—';

function useLoad(fn:any){
  const [rows,setRows]=useState<any[]>([]),[error,setError]=useState('');
  useEffect(()=>{void fn().then((r:any)=>{setRows(r.data||[]);setError(r.error?.message||'')})},[]);
  return {rows,error};
}

function vehicleCapacity(v:any){return Number(v.capacity??v.max_seats??v.default_max_seats??0)}

export function OperatorDetailRouteOffers({id}:{id:string}){
  const {rows:operators,error:operatorError}=useLoad(loadOperators);
  const {rows:vehicles}=useLoad(loadVehicles);
  const {rows:captains}=useLoad(loadCaptains);
  const {rows:types}=useLoad(loadVehicleTypes);
  const {rows:routes}=useLoad(loadRoutes);
  const {rows:offers}=useLoad(loadVehicleRouteOffers);
  const {rows:unavailability}=useLoad(loadVehicleUnavailability);
  const {rows:overrides}=useLoad(loadOperatorCommissionOverrides);
  const {rows:countryCommissions}=useLoad(loadCountryCommissions);
  const {rows:policies}=useLoad(loadCancellationPolicies);
  const {rows:routeVehicleTypes}=useLoad(loadRouteVehicleTypes);
  const {rows:operatorVehicleTypes}=useLoad(loadOperatorVehicleTypes);
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

  const addVehicle=async()=>{
    const name=window.prompt('Vehicle name'); if(!name?.trim())return;
    const typeNames=types.map(t=>t.name).join(', ');
    const typeName=window.prompt(`Vehicle type (${typeNames})`,types[0]?.name||''); if(!typeName)return;
    const type=types.find(t=>String(t.name).toLowerCase()===typeName.trim().toLowerCase());
    if(!type)return setMsg('Select an existing vehicle type by name.');
    const raw=window.prompt('Physical passenger capacity','12'); if(raw===null)return;
    const capacity=Number(raw); if(!Number.isInteger(capacity)||capacity<1)return setMsg('Physical passenger capacity must be a whole number greater than zero.');
    // The current production RPC still requires legacy commercial defaults. They are compatibility-only
    // and are deliberately not exposed as vehicle pricing. Route Offers are the commercial authority.
    await done(await adminCreateVehicle({
      p_operator_id:id,p_vehicle_type_id:type.id,p_name:name.trim(),p_description:null,
      p_min_seats:1,p_max_seats:capacity,p_min_revenue_cents:100000,
      p_min_value_threshold_ratio:null,p_max_seat_discount_bps:0
    }),'Vehicle');
  };

  const isRouteTypeAllowed=(route:any,vehicle:any)=>{
    const relevant=routeVehicleTypes.filter(x=>x.route_id===route.id&&x.active!==false&&!x.effective_to);
    return relevant.some(x=>x.vehicle_type_id===vehicle.vehicle_type_id);
  };
  const isOperatorTypeApproved=(vehicle:any)=>{
    const relevant=operatorVehicleTypes.filter(x=>x.operator_id===id&&x.vehicle_type_id===vehicle.vehicle_type_id&&!x.effective_to);
    return relevant.some(x=>x.approved!==false&&x.active!==false);
  };

  const addRouteOffer=async()=>{
    if(!fleet.length||!routes.length)return setMsg('Add a vehicle and ensure at least one route exists first.');
    const routeName=window.prompt(`Route (${routes.map(r=>r.route_name).join(', ')})`,routes[0]?.route_name||''); if(!routeName)return;
    const route=routes.find(r=>String(r.route_name).toLowerCase()===routeName.trim().toLowerCase());
    if(!route)return setMsg('Select an existing route by name.');
    const eligible=fleet.filter(v=>isRouteTypeAllowed(route,v)&&isOperatorTypeApproved(v));
    if(!eligible.length)return setMsg('No operator vehicle is approved and permitted for that route. Check route and operator vehicle-type approvals.');
    const vehicleName=window.prompt(`Vehicle (${eligible.map(v=>v.name).join(', ')})`,eligible[0]?.name||''); if(!vehicleName)return;
    const vehicle=eligible.find(v=>String(v.name).toLowerCase()===vehicleName.trim().toLowerCase());
    if(!vehicle)return setMsg('Select an eligible vehicle by name.');
    const capacity=vehicleCapacity(vehicle);
    const min=Number(window.prompt('Minimum seats','1')); if(!Number.isInteger(min)||min<1)return setMsg('Minimum seats must be a whole number greater than zero.');
    const max=Number(window.prompt(`Maximum seats (vehicle capacity ${capacity||'unknown'})`,String(capacity||min))); if(!Number.isInteger(max)||max<min)return setMsg('Maximum seats must be a whole number at least equal to minimum seats.');
    if(capacity&&max>capacity)return setMsg(`Maximum seats cannot exceed the vehicle capacity of ${capacity}.`);
    const revenue=Number(window.prompt('Minimum journey revenue (USD)','1000')); if(!Number.isFinite(revenue)||revenue<=0)return setMsg('Minimum journey revenue must be greater than zero.');
    const thresholdRaw=window.prompt('Minimum value threshold ratio (blank = route default)','');
    const threshold=thresholdRaw===''||thresholdRaw===null?null:Number(thresholdRaw);
    if(threshold!==null&&(!Number.isFinite(threshold)||threshold<=0))return setMsg('Minimum value threshold must be a positive number or blank.');
    const discountEnabled=window.confirm('Enable post-minimum seat discount?');
    const discountPct=discountEnabled?Number(window.prompt('Maximum post-minimum discount %','20')):0;
    if(!Number.isFinite(discountPct)||discountPct<0||discountPct>100)return setMsg('Discount must be between 0% and 100%.');
    await done(await adminCreateRouteOffer({
      p_vehicle_id:vehicle.id,p_route_id:route.id,p_min_seats:min,p_max_seats:max,
      p_min_revenue_cents:Math.round(revenue*100),p_preferred:false,
      p_min_value_threshold_ratio:threshold,p_post_min_discount_enabled:discountEnabled,
      p_post_min_discount_bps:Math.round(discountPct*100)
    }),'Route Offer');
  };

  return <>
    <Section title={operator.name} action={<Link className="btn" href="/operator">Operator Dashboard</Link>}>
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

    <div className="grid-2" style={{marginTop:12}}>
      <Section title="Fleet" action={<button className="btn secondary" onClick={addVehicle}>+ Add Vehicle</button>}>
        <p className="data-note">Vehicle records describe the physical and operational asset. Commercial pricing is configured separately for each Route Offer.</p>
        {fleet.map(v=><div className="notice" key={v.id}><span><b>{v.name}</b><br/><small>{v.vehicle_type_name||v.vehicle_type||'Vehicle'} · capacity {vehicleCapacity(v)||'—'}</small></span><Status value={v.active===false?'INACTIVE':'ACTIVE'}/></div>)}
        {!fleet.length&&<div className="empty-state">No vehicles.</div>}
      </Section>
      <Section title="Captains" action={<button className="btn secondary" onClick={async()=>{const first=window.prompt('Captain first name');if(!first)return;const last=window.prompt('Captain last name');if(!last)return;done(await adminCreateCaptain({p_operator_id:id,p_first_name:first,p_last_name:last,p_email:null,p_phone:null,p_notes:'Created by Site Admin'}),'Captain')}}>+ Add Captain</button>}>
        {crew.map(c=><div className="notice" key={c.id}><span><b>{c.first_name} {c.last_name}</b></span><Status value={c.active?'ACTIVE':'INACTIVE'}/></div>)}
        {!crew.length&&<div className="empty-state">No captains.</div>}
      </Section>
    </div>

    <Section title="Route Offers" action={<button className="btn secondary" onClick={addRouteOffer}>+ Add Route Offer</button>}>
      <p className="data-note"><b>Minimum journey revenue</b> is the minimum revenue required for this vehicle to perform the complete two-leg journey on this route. The operator chooses this figure and can use it to compete for allocations. The opposite direction is a separate Route Offer.</p>
      <table className="table"><thead><tr><th>Route</th><th>Vehicle</th><th>Min / max seats</th><th>Minimum journey revenue</th><th>Discount</th><th>Status</th><th>Control</th></tr></thead><tbody>
        {routeOffers.map(o=><tr key={o.id||o.offer_id}><td><b>{o.route_name}</b></td><td>{o.vehicle_name}</td><td>{o.min_seats} / {o.max_seats}</td><td>{money(o.min_revenue_cents)}</td><td>{o.post_min_discount_enabled?`${Number(o.post_min_discount_bps||0)/100}%`:'Off'}</td><td><Status value={o.active===false?'INACTIVE':'ACTIVE'}/></td><td><button className="btn secondary" onClick={async()=>done(await adminSetRouteOfferActive(o.id||o.offer_id,o.active===false),o.active===false?'Route Offer activated':'Route Offer paused')}>{o.active===false?'Activate':'Pause'}</button></td></tr>)}
        {!routeOffers.length&&<tr><td colSpan={7} className="empty-state">No Route Offers configured for this operator.</td></tr>}
      </tbody></table>
    </Section>

    <Section title="Vehicle Unavailability">
      {blocks.map(b=><div className="notice" key={b.id}><span><b>{b.vehicle_name}</b><br/><small>{date(b.start_ts)} → {date(b.end_ts)}</small></span><span>{b.reason_code||'Unavailable'}</span></div>)}
      {!blocks.length&&<div className="empty-state">No availability exceptions.</div>}
    </Section>
    {msg&&<p className={msg.toLowerCase().includes('saved')?'action-success':'action-error'}>{msg}</p>}
  </>;
}
