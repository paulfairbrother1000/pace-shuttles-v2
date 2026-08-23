'use client';
import Link from 'next/link';
import { useEffect, useMemo, useState } from 'react';
import { getSupabaseBrowserClient } from '@/lib/supabase';
import { loadAdminJourneys,loadAdminLiveOperationsDetail,loadAdminJourneyBookings,loadAdminJourneyAllocations,loadRoutePerformance,loadCountryPerformance,loadDestinationPerformance,loadOperatorPerformance,loadCaptains,loadCountries,loadDestinations,loadOperators,loadPickups,loadRoutes,loadSettlements,loadSupportInbox,loadVehicles,loadOperatorJourneys,loadCustomerBookings } from '@/lib/data';
import { KpiCard, RowLink, Section, Status } from './ui';
const money=(c:number)=>new Intl.NumberFormat('en-US',{style:'currency',currency:'USD',maximumFractionDigits:0}).format((c||0)/100);
const date=(x:any)=>x?new Date(x).toLocaleString():'—';
function useLoad(fn:any){const [rows,setRows]=useState<any[]>([]),[error,setError]=useState(''); useEffect(()=>{fn().then((r:any)=>{setRows(r.data||[]);setError(r.error?.message||'')})},[]); return {rows,error}}
export function JourneyDetail({id}:{id:string}){
  const {rows:detail,error:detailError}=useLoad(loadAdminLiveOperationsDetail);
  const {rows:bookings,error:bookingError}=useLoad(loadAdminJourneyBookings);
  const {rows:allocations,error:allocationError}=useLoad(loadAdminJourneyAllocations);
  const j=detail.find(x=>x.departure_id===id);
  const jb=bookings.filter(x=>x.departure_id===id);
  const ja=allocations.filter(x=>x.departure_id===id);
  const err=detailError||bookingError||allocationError;
  if(!j)return <Section title="Journey"><div className="empty-state">Loading journey or no access…</div></Section>;
  const totalCustomerRevenue=jb.reduce((n,x)=>n+Number(x.total_price_cents||0),0);
  const operatorValue=ja.reduce((n,x)=>n+Number(x.operator_journey_value_cents||0),0);
  const commission=ja.reduce((n,x)=>n+Number(x.pace_shuttles_commission_cents||0),0);
  const operatorNet=ja.reduce((n,x)=>n+Number(x.operator_net_before_adjustments_cents||0),0);
  return <>
    {err&&<p className="data-note">{err}</p>}
    <section className="card hero-strip">
      <div className="hero-cell"><small>Route</small><strong>{j.route_name}</strong><small>{[j.locality_name,j.region_name,j.country_name].filter(Boolean).join(' · ')||j.trip_timezone}</small></div>
      <div className="hero-cell"><small>Journey ID</small><strong>{j.departure_id.slice(0,8)}</strong></div>
      <div className="hero-cell"><small>Departure</small><strong>{date(j.scheduled_departure_ts)}</strong></div>
      <div className="hero-cell"><small>Bookings</small><strong>{j.booking_count}</strong></div>
      <div className="hero-cell"><small>Seats</small><strong>{j.booked_seats}</strong></div>
      <div className="hero-cell"><small>Vehicles</small><strong>{j.confirmed_vehicle_count}</strong></div>
      <div className="hero-cell"><small>Captains</small><strong>{j.active_captain_count}</strong></div>
      <div className="hero-cell"><small>Status</small><strong><Status value={String(j.departure_status).replaceAll('_',' ').toUpperCase()}/></strong></div>
    </section>

    <div className="grid-4" style={{marginTop:12}}>
      <div className="mini-metric"><small>Customer revenue</small><strong>{money(totalCustomerRevenue)}</strong></div>
      <div className="mini-metric"><small>Operator journey value</small><strong>{money(operatorValue)}</strong></div>
      <div className="mini-metric"><small>Pace commission</small><strong>{money(commission)}</strong></div>
      <div className="mini-metric"><small>Operator net</small><strong>{money(operatorNet)}</strong></div>
    </div>

    <div className="grid-3" style={{marginTop:12}}>
      <Section title="Operational Timeline">
        <RowLink href="#">T-72: {date(j.t72_ts)}</RowLink>
        <RowLink href="#">T-24: {date(j.t24_ts)}</RowLink>
        <RowLink href="#">Departure: {date(j.scheduled_departure_ts)}</RowLink>
        <RowLink href="#">Arrival: {date(j.scheduled_arrival_ts)}</RowLink>
      </Section>
      <Section title="Allocation & Crew">
        {ja.length?ja.map(x=><div className="notice" key={x.confirmed_allocation_id}><span><b>{x.operator_name}</b><br/>{x.vehicle_name}<br/><small>{x.captain_name||'No captain assigned'}</small></span><span><Status value={String(x.allocation_status||'CONFIRMED').toUpperCase()}/><br/><small>{((Number(x.effective_commission_bps||0))/100).toFixed(2)}% commission</small></span></div>):<div className="empty-state">No confirmed allocation.</div>}
      </Section>
      <Section title="Status & Admin">
        <div className="notice-list">
          {j.at_risk_reason&&<div className="notice warn"><span>At-risk reason</span><b>{j.at_risk_reason}</b></div>}
          {j.cancelled_reason&&<div className="notice bad"><span>Cancellation reason</span><b>{j.cancelled_reason}</b></div>}
          {!j.at_risk_reason&&!j.cancelled_reason&&<div className="notice"><span>Operational status</span><b>{String(j.departure_status).replaceAll('_',' ')}</b></div>}
        </div>
        <p className="data-note">Admin write actions will call V2 business functions rather than writing around allocation, cancellation or settlement controls.</p>
        <button className="btn secondary" disabled>Operational actions next</button>
      </Section>
    </div>

    <div className="grid-2" style={{marginTop:12}}>
      <Section title={`Bookings & Passenger Groups (${jb.length})`}>
        <table className="table"><thead><tr><th>Lead customer</th><th>Status</th><th>Seats</th><th>Unit price</th><th>Total</th><th>Paid</th></tr></thead><tbody>
          {jb.map(x=><tr key={x.booking_id}><td><b>{x.customer_name||x.lead_last_name||'Customer'}</b></td><td><Status value={String(x.booking_status).replaceAll('_',' ').toUpperCase()}/></td><td>{x.seats}</td><td>{money(x.unit_price_cents)}</td><td>{money(x.total_price_cents)}</td><td>{x.paid_at?'Yes':'No'}</td></tr>)}
          {!jb.length&&<tr><td colSpan={6} className="empty-state">No bookings for this journey.</td></tr>}
        </tbody></table>
      </Section>
      <Section title="Journey Financial Reconciliation">
        <div className="metric-pair">
          <div className="mini-metric"><small>Customer revenue</small><strong>{money(totalCustomerRevenue)}</strong></div>
          <div className="mini-metric"><small>Operator journey value</small><strong>{money(operatorValue)}</strong></div>
          <div className="mini-metric"><small>Pace commission</small><strong>{money(commission)}</strong></div>
          <div className="mini-metric"><small>Operator net</small><strong>{money(operatorNet)}</strong></div>
        </div>
        <p className="data-note">Customer revenue is what customers paid for the journey. Operator journey value is the amount used for operator settlement/commission calculations. They are intentionally shown separately.</p>
      </Section>
    </div>
  </>;
}
export function Analytics(){
 const {rows:j}=useLoad(loadAdminJourneys),{rows:c}=useLoad(loadCountryPerformance),{rows:r}=useLoad(loadRoutePerformance),{rows:d}=useLoad(loadDestinationPerformance),{rows:o}=useLoad(loadOperatorPerformance);
 const gross=r.reduce((n,x)=>n+Number(x.customer_revenue_cents||0),0),commission=r.reduce((n,x)=>n+Number(x.pace_commission_cents||0),0),operatorValue=r.reduce((n,x)=>n+Number(x.operator_journey_value_cents||0),0);
 const topRoutes=[...r].sort((a,b)=>Number(b.customer_revenue_cents||0)-Number(a.customer_revenue_cents||0));
 const topOps=[...o].sort((a,b)=>Number(b.operator_journey_value_cents||0)-Number(a.operator_journey_value_cents||0));
 const topDest=[...d].sort((a,b)=>Number(b.customer_revenue_cents||0)-Number(a.customer_revenue_cents||0));
 return <><div className="grid-4"><KpiCard label="Journeys" value={String(j.length)}/><KpiCard label="Customer Revenue" value={money(gross)}/><KpiCard label="Pace Commission" value={money(commission)}/><KpiCard label="Avg Commission Rate" value={operatorValue?`${(commission/operatorValue*100).toFixed(2)}%`:'—'}/></div>
 <div className="grid-2" style={{marginTop:12}}><Section title="Performance by Country"><table className="table"><thead><tr><th>Country</th><th>Trips</th><th>Customer revenue</th><th>Avg / trip</th><th>Operator value</th><th>Commission</th></tr></thead><tbody>{[...c].sort((a,b)=>Number(b.customer_revenue_cents||0)-Number(a.customer_revenue_cents||0)).map(x=><tr key={x.country_id}><td><b>{x.country_name}</b></td><td>{x.trips}</td><td>{money(x.customer_revenue_cents)}</td><td>{money(x.avg_customer_revenue_per_trip_cents)}</td><td>{money(x.operator_journey_value_cents)}</td><td>{money(x.pace_commission_cents)}</td></tr>)}</tbody></table></Section>
 <Section title="Journey Status"><div className="notice-list">{Object.entries(j.reduce((a:any,x:any)=>{const k=String(x.departure_status);a[k]=(a[k]||0)+1;return a},{})).map(([k,v])=><div className="notice" key={k}><span>{k.replaceAll('_',' ')}</span><b>{String(v)}</b></div>)}</div></Section></div>
 <div className="grid-3" style={{marginTop:12}}><Section title="Top Routes by Customer Revenue">{topRoutes.slice(0,8).map((x,i)=><div className="notice" key={x.route_id}><span>{i+1}. {x.route_name}<br/><small>{x.trips} trip(s) · avg {money(x.avg_customer_revenue_per_trip_cents)}</small></span><b>{money(x.customer_revenue_cents)}</b></div>)}</Section><Section title="Top Operators by Journey Value">{topOps.slice(0,8).map((x,i)=><div className="notice" key={x.operator_id}><span>{i+1}. {x.operator_name}<br/><small>{x.trips} trip(s) · avg {money(x.avg_operator_revenue_per_trip_cents)}</small></span><b>{money(x.operator_journey_value_cents)}</b></div>)}</Section><Section title="Top Destinations by Customer Revenue">{topDest.slice(0,8).map((x,i)=><div className="notice" key={x.destination_id}><span>{i+1}. {x.destination_name}<br/><small>{x.trips} trip(s) · avg {money(x.avg_customer_revenue_per_trip_cents)}</small></span><b>{money(x.customer_revenue_cents)}</b></div>)}</Section></div>
 <div className="grid-2" style={{marginTop:12}}><Section title="Bottom Routes by Revenue">{[...topRoutes].reverse().slice(0,8).map(x=><div className="notice" key={x.route_id}><span>{x.route_name}</span><b>{money(x.customer_revenue_cents)}</b></div>)}</Section><Section title="Operator Quality & Commission">{[...o].sort((a,b)=>Number(b.quality_score||0)-Number(a.quality_score||0)).map(x=><div className="notice" key={x.operator_id}><span>{x.operator_name}<br/><small>{x.trips} trip(s) · {x.avg_commission_rate_pct==null?'—':Number(x.avg_commission_rate_pct).toFixed(2)+'%'} avg commission</small></span><b>{x.quality_score??'—'}</b></div>)}</Section></div></>}
export function Operators(){const {rows,error}=useLoad(loadOperators); return <>{error&&<p className="data-note">{error}</p>}<Section title="Operators" action={<button className="btn">+ Add Operator</button>}><table className="table"><thead><tr><th>Operator</th><th>Town / Region</th><th>Quality</th><th>Stripe</th><th>Status</th><th></th></tr></thead><tbody>{rows.map(o=><tr key={o.id}><td><b>{o.name}</b></td><td>{[o.town,o.region].filter(Boolean).join(', ')||'—'}</td><td>{o.quality_score??'—'}</td><td>{o.stripe_onboarding_status||'—'}</td><td><Status value={o.active?'ACTIVE':'INACTIVE'}/></td><td><Link href={`/admin/operators/${o.id}`}>Manage →</Link></td></tr>)}</tbody></table></Section></>}
export function OperatorDetail({id}:{id:string}){const {rows:o}=useLoad(loadOperators),{rows:v}=useLoad(loadVehicles),{rows:c}=useLoad(loadCaptains); const x=o.find(z=>z.id===id); if(!x)return <Section title="Operator"><div className="empty-state">Loading operator…</div></Section>; const vv=v.filter(z=>z.operator_id===id),cc=c.filter(z=>z.operator_id===id); return <><Section title={x.name} action={<Link className="btn" href={`/admin/operators/${id}?operator=${encodeURIComponent(x.name)}`}>Manage as Operator</Link>}><div className="grid-4"><div className="mini-metric"><small>Quality</small><strong>{x.quality_score??'—'}</strong></div><div className="mini-metric"><small>Vehicles</small><strong>{vv.length}</strong></div><div className="mini-metric"><small>Captains</small><strong>{cc.length}</strong></div><div className="mini-metric"><small>Status</small><strong>{x.active?'Active':'Inactive'}</strong></div></div></Section><div className="grid-2" style={{marginTop:12}}><Section title="Fleet">{vv.map(z=><RowLink href="#" key={z.id}>{z.name} · {z.default_min_seats??'—'}–{z.default_max_seats??'—'} seats</RowLink>)}</Section><Section title="Captains">{cc.map(z=><RowLink href="#" key={z.id}>{z.first_name} {z.last_name} · {z.active?'Active':'Inactive'}</RowLink>)}</Section></div></>}
export function Finance(){const {rows:s}=useLoad(loadSettlements),{rows:o}=useLoad(loadOperators); const total=s.reduce((n,x)=>n+Number(x.journey_value_cents||0),0),comm=s.reduce((n,x)=>n+Number(x.commission_cents||0),0),net=s.reduce((n,x)=>n+Number(x.net_payable_cents||0),0); return <><div className="grid-4"><KpiCard label="Journey Value" value={money(total)}/><KpiCard label="Pace Commission" value={money(comm)}/><KpiCard label="Net Payable" value={money(net)}/><KpiCard label="Settlements" value={String(s.length)}/></div><Section title="Settlements"><table className="table"><thead><tr><th>Operator</th><th>Journey Value</th><th>Commission</th><th>Rate</th><th>Net Payable</th><th>Status</th></tr></thead><tbody>{s.map(x=><tr key={x.id}><td>{o.find(z=>z.id===x.operator_id)?.name||x.operator_id?.slice(0,8)}</td><td>{money(x.journey_value_cents)}</td><td>{money(x.commission_cents)}</td><td>{((x.effective_commission_bps||0)/100).toFixed(2)}%</td><td>{money(x.net_payable_cents)}</td><td><Status value={String(x.status).toUpperCase()}/></td></tr>)}</tbody></table></Section></>}
export function Network(){const {rows:c}=useLoad(loadCountries),{rows:r}=useLoad(loadRoutes),{rows:d}=useLoad(loadDestinations),{rows:p}=useLoad(loadPickups); return <><div className="grid-4"><KpiCard label="Countries" value={String(c.length)}/><KpiCard label="Routes" value={String(r.length)}/><KpiCard label="Pick Ups" value={String(p.length)}/><KpiCard label="Destinations" value={String(d.length)}/></div><div className="grid-2" style={{marginTop:12}}><Section title="Countries">{c.map(x=><RowLink href="#" key={x.id}>{x.name} · {x.active?'Active':'Inactive'}</RowLink>)}</Section><Section title="Routes"><table className="table"><thead><tr><th>Route</th><th>Timezone</th><th>Status</th></tr></thead><tbody>{r.map(x=><tr key={x.id}><td>{x.route_name}</td><td>{x.trip_timezone}</td><td><Status value={x.is_active?'ACTIVE':'INACTIVE'}/></td></tr>)}</tbody></table></Section></div></>}
export function Support(){const {rows}=useLoad(loadSupportInbox); return <div className="grid-2"><Section title="Support Inbox">{rows.map(x=><RowLink href="#" key={x.conversation_id}>{x.ticket_number?`#${x.ticket_number} · `:''}{x.category||x.channel} · {x.ticket_status||x.conversation_status}</RowLink>)}{!rows.length&&<div className="empty-state">No support items.</div>}</Section><Section title="Administration"><RowLink href="/admin/settings">Commissions & Fees</RowLink><RowLink href="/admin/settings">Cancellation Policies</RowLink><RowLink href="/admin/settings">Roles & Permissions</RowLink><RowLink href="/admin/settings">Payment Providers</RowLink></Section></div>}
export function OperatorMobile(){const {rows}=useLoad(loadOperatorJourneys); return <Section title="Operator Journeys">{rows.map(x=><RowLink href="#" key={x.confirmed_allocation_id}>{date(x.scheduled_departure_ts)} · {x.route_name} · {money(x.operator_net_before_adjustments_cents)}</RowLink>)}{!rows.length&&<div className="empty-state">No operator journeys visible for this account.</div>}</Section>}
export function CaptainMobile(){return <div className="grid-2"><Section title="Captain App"><p>Captain authentication and journey execution will use the existing V2 captain functions.</p><p className="data-note">This screen is intentionally locked until a captain identity is linked to an authenticated user.</p></Section><Section title="Safety"><p>Start/complete journey controls will only be enabled for the captain assigned to the confirmed allocation.</p></Section></div>}
export function CustomerSearch(){const {rows}=useLoad(loadCustomerBookings); return <Section title="My Bookings">{rows.map(x=><RowLink href="#" key={x.booking_id}>{date(x.scheduled_departure_ts)} · {x.route_name} · {x.seats} seat(s) · {money(x.total_price_cents)}</RowLink>)}{!rows.length&&<div className="empty-state">No bookings visible for this signed-in user.</div>}</Section>}
