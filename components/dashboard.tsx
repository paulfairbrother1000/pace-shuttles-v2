'use client';
import Link from 'next/link';
import { useEffect, useMemo, useState } from 'react';
import { loadAdminJourneys, loadAdminLiveOperationsDetail, loadOperators, loadSettlements } from '@/lib/data';
import { KpiCard, Section, Status } from './ui';
const money=(c:number)=>new Intl.NumberFormat('en-US',{style:'currency',currency:'USD',maximumFractionDigits:0}).format((c||0)/100);
const when=(x:any)=>x?new Date(x).toLocaleString([], {month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'}):'—';
export function Dashboard(){
  const [j,setJ]=useState<any[]>([]),[live,setLive]=useState<any[]>([]),[o,setO]=useState<any[]>([]),[s,setS]=useState<any[]>([]),[err,setErr]=useState('');
  useEffect(()=>{Promise.all([loadAdminJourneys(),loadAdminLiveOperationsDetail(),loadOperators(),loadSettlements()]).then(([a,l,b,c])=>{setJ(a.data);setLive(l.data);setO(b.data);setS(c.data);setErr(a.error?.message||l.error?.message||b.error?.message||c.error?.message||'')})},[]);
  const m=useMemo(()=>{
    const grossRevenue=live.reduce((x,r)=>x+Number(r.customer_revenue_cents||0),0);
    const operatorJourneyValue=s.reduce((x,r)=>x+Number(r.journey_value_cents||0),0);
    const commission=s.reduce((x,r)=>x+Number(r.commission_cents||0),0);
    return {grossRevenue,operatorJourneyValue,commission,avgGross:j.length?grossRevenue/j.length:0,confirmed:j.filter(x=>String(x.departure_status).toLowerCase()==='confirmed').length,atRisk:j.filter(x=>['at_risk','under_consideration'].includes(String(x.departure_status).toLowerCase())).length,seats:j.reduce((x,r)=>x+Number(r.booked_seats||0),0)}
  },[j,live,s]);
  return <>
    <div className="kpi-grid">
      <KpiCard label="Gross Customer Revenue" value={money(m.grossRevenue)}/><KpiCard label="Total Journeys" value={String(j.length)}/><KpiCard label="Booked Seats" value={String(m.seats)}/><KpiCard label="Total Commission" value={money(m.commission)}/><KpiCard label="Avg Commission Rate" value={m.operatorJourneyValue?`${(m.commission/m.operatorJourneyValue*100).toFixed(2)}%`:'—'}/><KpiCard label="Avg Customer Revenue / Trip" value={money(m.avgGross)}/><KpiCard label="Operators" value={String(o.length)}/><KpiCard label="Confirmed" value={String(m.confirmed)}/>
    </div>
    {err&&<p className="data-note">Live data requires an authenticated Site Admin session. {err}</p>}
    <div className="dashboard-grid">
      <Section title="Live Network"><table className="table"><thead><tr><th>Route</th><th>Departure</th><th>Status</th><th>Bookings</th><th>Seats</th></tr></thead><tbody>{j.slice(0,8).map(x=><tr key={x.departure_id}><td><Link href={`/admin/journeys/${x.departure_id}`}>{x.route_name}</Link></td><td>{when(x.scheduled_departure_ts)}</td><td><Status value={String(x.departure_status).replaceAll('_',' ').toUpperCase()}/></td><td>{x.booking_count}</td><td>{x.booked_seats}</td></tr>)}{!j.length&&<tr><td colSpan={5} className="empty-state">No journeys visible.</td></tr>}</tbody></table></Section>
      <Section title="Revenue & Commission"><div className="metric-pair"><div className="mini-metric"><small>Customer revenue</small><strong>{money(m.grossRevenue)}</strong></div><div className="mini-metric"><small>Operator journey value</small><strong>{money(m.operatorJourneyValue)}</strong></div><div className="mini-metric"><small>Pace commission</small><strong>{money(m.commission)}</strong></div><div className="mini-metric"><small>Settlements</small><strong>{s.length}</strong></div></div><p className="data-note">Customer revenue and operator journey value are separate metrics. Commission rate is calculated against operator journey value.</p></Section>
      <Section title="Operator Quality">{o.sort((a,b)=>Number(b.quality_score||0)-Number(a.quality_score||0)).slice(0,7).map(x=><div className="notice" key={x.id}><span>{x.name}</span><b>{x.quality_score??'—'}</b></div>)}</Section>
    </div>
    <Section title="Today / Live Operations" action={<Link className="btn secondary" href="/admin/live-operations">Go to Live Operations</Link>}><div className="grid-4"><div className="mini-metric"><small>Journeys in data set</small><strong>{j.length}</strong></div><div className="mini-metric"><small>Confirmed</small><strong>{m.confirmed}</strong></div><div className="mini-metric"><small>Bookings</small><strong>{j.reduce((x,r)=>x+Number(r.booking_count||0),0)}</strong></div><div className="mini-metric"><small>Booked seats</small><strong>{m.seats}</strong></div></div></Section>
  </>
}
export function LiveOperations(){
  const [rows,setRows]=useState<any[]>([]),[err,setErr]=useState(''),[search,setSearch]=useState(''),[status,setStatus]=useState('ALL'),[country,setCountry]=useState('ALL');
  useEffect(()=>{loadAdminLiveOperationsDetail().then(r=>{setRows(r.data);setErr(r.error?.message||'')})},[]);
  const countries=useMemo(()=>[...new Set(rows.map(x=>x.country_name).filter(Boolean))].sort(),[rows]);
  const filtered=useMemo(()=>rows.filter(x=>{
    const q=search.trim().toLowerCase();
    const matchesQ=!q||[x.route_name,x.country_name,x.region_name,x.locality_name,x.operator_names,x.vehicle_names,x.captain_names].some(v=>String(v||'').toLowerCase().includes(q));
    const matchesStatus=status==='ALL'||String(x.departure_status).toUpperCase()===status;
    const matchesCountry=country==='ALL'||x.country_name===country;
    return matchesQ&&matchesStatus&&matchesCountry;
  }),[rows,search,status,country]);
  const confirmed=filtered.filter(x=>String(x.departure_status).toLowerCase()==='confirmed').length;
  const consideration=filtered.filter(x=>['under_consideration','at_risk'].includes(String(x.departure_status).toLowerCase())).length;
  const seats=filtered.reduce((n,x)=>n+Number(x.booked_seats||0),0);
  const revenue=filtered.reduce((n,x)=>n+Number(x.customer_revenue_cents||0),0);
  return <>
    <div className="grid-4"><KpiCard label="Journeys" value={String(filtered.length)}/><KpiCard label="Confirmed" value={String(confirmed)}/><KpiCard label="At Risk / Consideration" value={String(consideration)}/><KpiCard label="Booked Seats" value={String(seats)}/></div>
    {err&&<p className="data-note">{err}</p>}
    <Section title="Live Operations" action={<span className="data-note">Customer revenue {money(revenue)}</span>}>
      <div className="toolbar"><input value={search} onChange={e=>setSearch(e.target.value)} placeholder="Search route, operator, vehicle, captain or place…"/><select value={country} onChange={e=>setCountry(e.target.value)}><option value="ALL">All countries</option>{countries.map(x=><option key={x} value={x}>{x}</option>)}</select><select value={status} onChange={e=>setStatus(e.target.value)}><option value="ALL">All statuses</option><option value="UNDER_CONSIDERATION">Under consideration</option><option value="AT_RISK">At risk</option><option value="CONFIRMED">Confirmed</option><option value="COMPLETED">Completed</option><option value="CANCELLED">Cancelled</option></select></div>
      <div className="journey-list">{filtered.map(x=><Link href={`/admin/journeys/${x.departure_id}`} className="journey-card live-detail" key={x.departure_id}>
        <div><Status value={String(x.departure_status).replaceAll('_',' ').toUpperCase()}/><b style={{marginTop:6}}>{when(x.scheduled_departure_ts)}</b></div>
        <div><b>{x.route_name}</b><small>{[x.locality_name,x.region_name,x.country_name].filter(Boolean).join(' · ')||x.trip_timezone}</small></div>
        <div><b>{x.operator_names||'Unallocated'}</b><small>{x.vehicle_names||'No vehicle confirmed'}</small></div>
        <div className="desktop-only"><b>{x.captain_names||'No captain'}</b><small>{x.active_captain_count} active captain(s)</small></div>
        <div><b>{x.booked_seats} seats</b><small>{x.booking_count} booking(s)</small></div>
        <div><b>{money(x.customer_revenue_cents)}</b><small>customer revenue</small></div>
        <div className="desktop-only"><b>T-24 {when(x.t24_ts)}</b><small>T-72 {when(x.t72_ts)}</small></div><div>View →</div>
      </Link>)}{!filtered.length&&<div className="empty-state">No journeys match these filters.</div>}</div>
    </Section>
  </>
}