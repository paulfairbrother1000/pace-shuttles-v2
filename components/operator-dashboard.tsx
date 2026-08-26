'use client';
import {useEffect,useMemo,useState} from 'react';
import {
 loadOperatorJourneys,loadOperatorConsiderations,loadOperatorFleet,loadOperatorRouteOffers,
 loadOperatorUnavailability,loadOperatorQuality,loadOperatorFairness,
 loadOperatorVehicleEditor,loadOperatorVehicleEditorCaptains,loadOperatorVehicleEditorTypes,
 loadOperatorVehicleEditorRoutes,loadOperatorVehicleEditorOffers,operatorSaveVehicle,
 operatorWithdrawConsideration,operatorAddUnavailability,operatorRemoveUnavailability,
 operatorSetRouteOfferActive,operatorUpdateRouteOffer
} from '@/lib/data';
import {KpiCard,Section,Status} from './ui';
import {vehicleCapacity} from '@/lib/vehicle-capacity';
import {operatorIdentity,operatorIdentityError,OperatorMembershipIdentity} from '@/lib/operator-identity';
import {getSupabaseBrowserClient} from '@/lib/supabase';
import {OperatorVehicleEditor} from './operator-vehicle-editor';

const money=(c:any)=>new Intl.NumberFormat('en-US',{style:'currency',currency:'USD',maximumFractionDigits:0}).format(Number(c||0)/100);
const when=(x:any)=>x?new Date(x).toLocaleString([],{weekday:'short',day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'}):'—';
const norm=(x:any)=>String(x||'').toLowerCase();
const label=(x:any)=>String(x||'—').replaceAll('_',' ');

function useRows(fn:any){
 const [rows,setRows]=useState<any[]>([]),[error,setError]=useState('');
 const reload=async()=>{const r=await fn();setRows(r.data||[]);setError(r.error?.message||'')};
 useEffect(()=>{void reload()},[]);
 return {rows,error,reload};
}

export function OperatorDashboard(){
 const journeys=useRows(loadOperatorJourneys);
 const considerations=useRows(loadOperatorConsiderations);
 const fleet=useRows(loadOperatorFleet);
 const offers=useRows(loadOperatorRouteOffers);
 const blocks=useRows(loadOperatorUnavailability);
 const quality=useRows(loadOperatorQuality);
 const fairness=useRows(loadOperatorFairness);
 const editorVehicles=useRows(loadOperatorVehicleEditor);
 const editorCaptains=useRows(loadOperatorVehicleEditorCaptains);
 const editorTypes=useRows(loadOperatorVehicleEditorTypes);
 const editorRoutes=useRows(loadOperatorVehicleEditorRoutes);
 const editorOffers=useRows(loadOperatorVehicleEditorOffers);
 const [tab,setTab]=useState('overview'),[msg,setMsg]=useState(''),[busy,setBusy]=useState('');

 const refresh=async()=>Promise.all([journeys.reload(),considerations.reload(),fleet.reload(),offers.reload(),blocks.reload(),quality.reload(),fairness.reload(),editorVehicles.reload(),editorCaptains.reload(),editorTypes.reload(),editorRoutes.reload(),editorOffers.reload()]);
 const run=async(name:string,fn:()=>Promise<any>)=>{setBusy(name);setMsg('');const r=await fn();setBusy('');if(r.error)setMsg(r.error.message||String(r.error));else{setMsg(name+' completed');await refresh()}};

 const under=considerations.rows.filter(x=>['eligible','open','filling_minimum','minimum_achieved','under_consideration'].includes(norm(x.status)));
 const confirmed=journeys.rows.filter(x=>['confirmed','booked','active'].includes(norm(x.departure_status)||norm(x.allocation_status)));
 const completed=journeys.rows.filter(x=>norm(x.departure_status)==='completed'||x.actual_arrival_ts);
 const earnings=journeys.rows.reduce((n,x)=>n+Number(x.net_payable_cents||x.operator_net_before_adjustments_cents||0),0);
 const q=quality.rows[0]||{};
 const fair=fairness.rows[0]||{};

 const tabs=[['overview','Overview'],['consideration','Under consideration'],['confirmed','Confirmed'],['completed','Completed'],['fleet','Fleet & availability'],['quality','Quality & fairness']];

 return <>
   <OperatorIdentityBanner/>
   <div className="grid-4">
     <KpiCard label="Under consideration" value={String(under.length)}/>
     <KpiCard label="Confirmed / active" value={String(confirmed.length)}/>
     <KpiCard label="Completed" value={String(completed.length)}/>
     <KpiCard label="Earnings / payable" value={money(earnings)}/>
   </div>

   <div className="tabs" style={{marginTop:14}}>
     {tabs.map(([id,name])=><a href="#" className={tab===id?'active':''} key={id} onClick={e=>{e.preventDefault();setTab(id)}}>{name}</a>)}
   </div>

   {msg&&<p className={msg.includes('completed')?'action-success':'action-error'}>{msg}</p>}

   {tab==='overview'&&<Overview under={under} confirmed={confirmed} q={q} fair={fair}/>}
   {tab==='consideration'&&<Consideration rows={under} busy={busy} run={run}/>}
   {tab==='confirmed'&&<JourneyList title="Trips Confirmed" rows={confirmed} confirmed/>}
   {tab==='completed'&&<JourneyList title="Trips Completed" rows={completed}/>}
   {tab==='fleet'&&<FleetEditor vehicles={editorVehicles.rows} offers={editorOffers.rows} captains={editorCaptains.rows} routes={editorRoutes.rows} vehicleTypes={editorTypes.rows} blocks={blocks.rows} busy={busy} setBusy={setBusy} setMsg={setMsg} refresh={refresh}/>}
   {tab==='quality'&&<Quality quality={quality.rows} fairness={fairness.rows}/>}

   {(journeys.error||considerations.error||fleet.error||offers.error)&&
     <p className="action-error">{journeys.error||considerations.error||fleet.error||offers.error}</p>}
 </>;
}

function OperatorIdentityBanner(){
 const [identity,setIdentity]=useState(()=>operatorIdentity({}));
 const [error,setError]=useState(''),[retry,setRetry]=useState(0);
 useEffect(()=>{
   const supabase=getSupabaseBrowserClient();
   if(!supabase){setError('Supabase is not configured.');return;}
   setError('');
   void Promise.all([supabase.auth.getUser(),supabase.rpc('v2_current_access_context')]).then(([userResult,accessResult])=>{
     const requestError=operatorIdentityError({accountError:userResult.error,accessError:accessResult.error});
     if(requestError){setError(requestError);return;}
     const access=Array.isArray(accessResult.data)?accessResult.data[0]:accessResult.data;
     setIdentity(operatorIdentity({
       accountEmail:userResult.data.user?.email,
       operatorMemberships:(access?.operator_memberships||[]) as OperatorMembershipIdentity[],
     }));
   }).catch(requestError=>setError(requestError instanceof Error?requestError.message:'Operator identity is unavailable.'));
 },[retry]);
 return <section className="operator-identity" aria-label="Signed-in operator identity">
   <div>
     <small>Operating as</small>
     {error
       ? <strong>Operator identity unavailable</strong>
       : identity.memberships.length
       ? identity.memberships.map((membership,index)=><strong key={`${membership.operatorName}-${membership.roleLabel}-${index}`}>{membership.operatorName} · {membership.roleLabel}</strong>)
       : <strong>Loading operator access…</strong>}
   </div>
   <div><small>Signed-in account</small>{error?<button className="link-button" onClick={()=>setRetry(value=>value+1)}>Retry</button>:<span>{identity.accountEmail||'Loading account…'}</span>}</div>
 </section>;
}

function Overview({under,confirmed,q,fair}:{under:any[],confirmed:any[],q:any,fair:any}){
 return <div className="dashboard-grid">
   <Section title="Trips under consideration">
     {under.slice(0,6).map(x=><div className="notice" key={x.consideration_id||x.id}><span><b>{x.route_name}</b><br/><small>{when(x.scheduled_departure_ts)} · {x.vehicle_name}</small></span><span><Status value={String(x.status||'UNDER CONSIDERATION').toUpperCase()}/><br/><small>{x.assigned_seats||0}/{x.min_seats||x.normal_min_seats||0} min seats</small></span></div>)}
     {!under.length&&<div className="empty-state">No journeys currently under consideration.</div>}
   </Section>
   <Section title="Trips confirmed">
     {confirmed.slice(0,6).map(x=><div className="notice" key={x.confirmed_allocation_id||x.departure_id}><span><b>{x.route_name}</b><br/><small>{when(x.scheduled_departure_ts)} · {x.vehicle_name}</small></span><span><Status value="CONFIRMED"/><br/><small>{x.booked_seats||x.assigned_seats||0} seats</small></span></div>)}
     {!confirmed.length&&<div className="empty-state">No confirmed journeys.</div>}
   </Section>
   <Section title="Performance">
     <div className="metric-pair">
       <div className="mini-metric"><small>Quality score</small><strong>{q.quality_score??q.current_score??'—'}</strong></div>
       <div className="mini-metric"><small>NPS</small><strong>{q.nps_score??q.nps??'—'}</strong></div>
       <div className="mini-metric"><small>Fairness wins</small><strong>{fair.wins??fair.total_wins??'—'}</strong></div>
       <div className="mini-metric"><small>Fairness losses</small><strong>{fair.losses??fair.total_losses??'—'}</strong></div>
     </div>
     <p className="data-note">Quality breaks equal-price allocation ties. The fairness ledger records true ties so repeated luck does not systematically favour the same operator.</p>
   </Section>
 </div>;
}

function Consideration({rows,busy,run}:{rows:any[],busy:string,run:any}){
 return <Section title="Trips Under Consideration">
   <p className="data-note">These are journeys where your vehicle is still competing for allocation. Withdrawal is only offered while the consideration remains withdrawable; confirmed journeys cannot be withdrawn here.</p>
   {rows.map(x=>{
     const canWithdraw=x.can_withdraw!==false&&!['confirmed','cancelled','withdrawn'].includes(norm(x.status));
     return <div className="journey-card" key={x.consideration_id||x.id}>
       <div><b>{when(x.scheduled_departure_ts)}</b><small>{x.trip_timezone||''}</small></div>
       <div><b>{x.route_name}</b><small>{x.vehicle_name} · {x.operator_name||''}</small></div>
       <div><small>Assigned</small><b>{x.assigned_seats||0} seats</b></div>
       <div><small>Revenue</small><b>{money(x.assigned_revenue_cents)}</b></div>
       <div><small>Minimum</small><b>{x.min_seats||x.normal_min_seats||0} seats · {money(x.min_revenue_cents)}</b></div>
       <div><Status value={String(x.status).toUpperCase()}/></div>
       <div><small>Stage</small><b>{label(x.allocation_stage||x.stage)}</b></div>
       <div>{canWithdraw?<button className="btn danger" disabled={!!busy} onClick={()=>{const reason=window.prompt('Why are you withdrawing this vehicle from consideration?');if(reason&&window.confirm('Withdraw this vehicle from this journey?'))run('Withdrawal',()=>operatorWithdrawConsideration(x.consideration_id||x.id,reason))}}>Withdraw</button>:<small>Locked</small>}</div>
     </div>
   })}
   {!rows.length&&<div className="empty-state">No trips are currently under consideration.</div>}
 </Section>;
}

function JourneyList({title,rows,confirmed=false}:{title:string,rows:any[],confirmed?:boolean}){
 return <Section title={title}>
   {rows.map(x=><div className="journey-card" key={x.confirmed_allocation_id||x.departure_id}>
     <div><b>{when(x.scheduled_departure_ts)}</b></div>
     <div><b>{x.route_name}</b><small>{x.vehicle_name}</small></div>
     <div><small>Seats</small><b>{x.booked_seats||x.assigned_seats||0}</b></div>
     <div><small>Journey value</small><b>{money(x.operator_journey_value_cents||x.assigned_revenue_cents)}</b></div>
     <div><small>Commission</small><b>{money(x.pace_shuttles_commission_cents)}</b></div>
     <div><small>Net</small><b>{money(x.net_payable_cents||x.operator_net_before_adjustments_cents)}</b></div>
     <div><Status value={String(x.departure_status||x.allocation_status||(confirmed?'CONFIRMED':'COMPLETED')).toUpperCase()}/></div>
     <div><small>{x.captain_name||'Captain pending'}</small></div>
   </div>)}
   {!rows.length&&<div className="empty-state">No journeys in this section.</div>}
 </Section>;
}

function FleetEditor({vehicles,offers,captains,routes,vehicleTypes,busy,setBusy,setMsg,refresh}:{vehicles:any[],offers:any[],captains:any[],routes:any[],vehicleTypes:any[],blocks:any[],busy:string,setBusy:any,setMsg:any,refresh:any}){
 const save=async(payload:Record<string,unknown>)=>{
  setBusy('Vehicle save');setMsg('');
  const result=await operatorSaveVehicle(payload);
  setBusy('');
  if(result.error){setMsg(result.error.message||String(result.error));return false;}
  setMsg('Vehicle saved');await refresh();return true;
 };
 const block=(v:any)=>{const start=window.prompt('Unavailable from (YYYY-MM-DD HH:MM)');if(!start)return;const end=window.prompt('Unavailable until (YYYY-MM-DD HH:MM)');if(!end)return;const note=window.prompt('Reason / note','Maintenance')||'Unavailable';setBusy('Vehicle unavailability');void operatorAddUnavailability(v.vehicle_id||v.id,new Date(start).toISOString(),new Date(end).toISOString(),'operator_unavailable',note).then(async result=>{setBusy('');if(result.error)setMsg(result.error.message);else{setMsg('Vehicle unavailability completed');await refresh()}})};
 return <OperatorVehicleEditor vehicles={vehicles} offers={offers} captains={captains} routes={routes} vehicleTypes={vehicleTypes} busy={!!busy} onSave={save} onBlockDates={block}/>;
}

function Fleet({fleet,blocks,busy,run}:{fleet:any[],blocks:any[],busy:string,run:any}){
 const addBlock=(v:any)=>{const start=window.prompt('Unavailable from (YYYY-MM-DD HH:MM)');if(!start)return;const end=window.prompt('Unavailable until (YYYY-MM-DD HH:MM)');if(!end)return;const note=window.prompt('Reason / note','Maintenance')||'Unavailable';run('Vehicle unavailability',()=>operatorAddUnavailability(v.vehicle_id||v.id,new Date(start).toISOString(),new Date(end).toISOString(),'operator_unavailable',note))};
 return <div className="grid-2">
   <Section title="Fleet">
     {fleet.map(v=><div className="notice" key={v.vehicle_id||v.id}><span><b>{v.name}</b><br/><small>{v.vehicle_type_name||v.vehicle_type} · capacity {vehicleCapacity(v)||'—'} seats</small></span><span><Status value={v.active===false?'INACTIVE':'ACTIVE'}/><button className="btn secondary" style={{marginLeft:8}} disabled={!!busy} onClick={()=>addBlock(v)}>Block dates</button></span></div>)}
     {!fleet.length&&<div className="empty-state">No vehicles linked to this operator.</div>}
   </Section>
   <Section title="Availability exceptions">
     {blocks.map(x=><div className="notice" key={x.exception_id||x.id}><span><b>{x.vehicle_name}</b><br/><small>{when(x.start_ts)} → {when(x.end_ts)}<br/>{x.reason_note||label(x.reason_code)}</small></span><button className="btn secondary" disabled={!!busy} onClick={()=>run('Availability restored',()=>operatorRemoveUnavailability(x.exception_id||x.id))}>Remove block</button></div>)}
     {!blocks.length&&<div className="empty-state">No future vehicle blocks.</div>}
   </Section>
 </div>;
}

function Offers({rows,busy,run}:{rows:any[],busy:string,run:any}){
 const edit=(x:any)=>{
   const min=Number(window.prompt('Minimum seats',String(x.min_seats??1))); if(!Number.isFinite(min))return;
   const max=Number(window.prompt('Maximum seats',String(x.max_seats??min))); if(!Number.isFinite(max))return;
   const rev=Number(window.prompt('Minimum journey revenue (USD)',String(Number(x.min_revenue_cents||0)/100))); if(!Number.isFinite(rev))return;
   const thresholdRaw=window.prompt('Minimum value threshold ratio (blank = route default)',x.min_value_threshold_ratio==null?'':String(x.min_value_threshold_ratio));
   const threshold=thresholdRaw===''||thresholdRaw===null?null:Number(thresholdRaw);
   const disc=window.confirm('Enable post-minimum seat discount?');
   const discPct=disc?Number(window.prompt('Maximum discount %',String(Number(x.post_min_discount_bps||0)/100))||0):0;
   run('Route offer update',()=>operatorUpdateRouteOffer(x.offer_id||x.id,min,max,Math.round(rev*100),!!x.preferred,threshold,disc,Math.round(discPct*100)));
 };
 return <Section title="Route participation & commercial offers">
   <p className="data-note">These values feed the same allocation/pricing engine used by the customer booking flow. Changes affect future live consideration calculations.</p>
   <table className="table"><thead><tr><th>Route</th><th>Vehicle</th><th>Min / max seats</th><th>Minimum revenue</th><th>Discount</th><th>Status</th><th>Controls</th></tr></thead><tbody>
   {rows.map(x=><tr key={x.offer_id||x.id}><td><b>{x.route_name}</b></td><td>{x.vehicle_name}</td><td>{x.min_seats} / {x.max_seats}</td><td>{money(x.min_revenue_cents)}</td><td>{x.post_min_discount_enabled?`${Number(x.post_min_discount_bps||0)/100}%`:'Off'}</td><td><Status value={x.active===false?'INACTIVE':'ACTIVE'}/></td><td><div className="action-buttons"><button className="btn secondary" disabled={!!busy} onClick={()=>edit(x)}>Edit</button><button className="btn secondary" disabled={!!busy} onClick={()=>run(x.active===false?'Offer enabled':'Offer disabled',()=>operatorSetRouteOfferActive(x.offer_id||x.id,x.active===false))}>{x.active===false?'Enable':'Disable'}</button></div></td></tr>)}
   </tbody></table>
   {!rows.length&&<div className="empty-state">No route offers configured for this operator.</div>}
 </Section>;
}

function Quality({quality,fairness}:{quality:any[],fairness:any[]}){
 return <div className="grid-2">
   <Section title="Quality score">
     {quality.map((x,i)=><div className="notice" key={x.operator_id||i}><span><b>{x.operator_name||'Operator quality'}</b><br/><small>Rolling evidence from customer feedback and attributed journey outcomes</small></span><span><b>{x.quality_score??x.current_score??'—'}</b><br/><small>NPS {x.nps_score??x.nps??'—'}</small></span></div>)}
     {!quality.length&&<div className="empty-state">No quality evidence calculated yet.</div>}
   </Section>
   <Section title="Allocation fairness ledger">
     {fairness.map((x,i)=><div className="notice" key={x.id||i}><span><b>{x.route_name||x.scope_name||'Allocation ties'}</b><br/><small>{x.total_ties??0} exact ties recorded</small></span><span><b>{x.wins??x.total_wins??0} won</b><br/><small>{x.losses??x.total_losses??0} lost</small></span></div>)}
     {!fairness.length&&<div className="empty-state">No exact-price fairness ties have been recorded yet.</div>}
     <p className="data-note">The ledger is transparent evidence, not a guaranteed allocation quota. Price and quality remain the primary allocation inputs.</p>
   </Section>
 </div>;
}
