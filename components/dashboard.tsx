'use client';
import Link from 'next/link';
import { countries, journeys, kpis, operators } from '@/lib/mock';
import { KpiCard, Progress, Section, Status } from './ui';

export function Dashboard(){return <>
  <div className="kpi-grid">{kpis.map(x=><KpiCard key={x.label} {...x}/>)}</div>
  <div className="dashboard-grid">
    <Section title="Performance by Geography" action={<button className="btn secondary">View all countries</button>}>
      <table className="table"><thead><tr><th>Country</th><th>Trips</th><th>Revenue</th><th>Avg Rev / Trip</th><th>Commission</th><th>Avg Comm %</th><th>Load</th></tr></thead><tbody>{countries.map(c=><tr key={c[0]}>{c.map((v,i)=><td key={i}>{v}</td>)}</tr>)}</tbody></table>
    </Section>
    <Section title="Revenue Trend"><div className="chart-placeholder"><div className="chart-line"/></div></Section>
    <Section title="Outliers / Needs Attention"><div className="notice-list"><div className="notice bad"><span>Route cancellation rate 2.4× higher<br/><small>Miami Beach → Airport</small></span><b>6.8%</b></div><div className="notice bad"><span>Operator quality down 8 points<br/><small>Sunshine Transfers</small></span><b>62.1</b></div><div className="notice warn"><span>Country load factor below average<br/><small>BVI</small></span><b>54.3%</b></div><div className="notice"><span>Destination demand up 37%<br/><small>Nobu, Antigua</small></span><b className="up">+37%</b></div></div></Section>
  </div>
  <div className="grid-4" style={{marginTop:12}}>
    <Section title="Top Routes by Revenue"><table className="table"><tbody>{journeys.slice(0,4).map((j,i)=><tr key={j.id}><td>{i+1}</td><td>{j.route}</td><td>{j.revenue}</td></tr>)}</tbody></table></Section>
    <Section title="Top Operators by Revenue"><table className="table"><tbody>{operators.map((o,i)=><tr key={o.id}><td>{i+1}</td><td><Link href={`/admin/operators/${o.id}`}>{o.name}</Link></td><td>{o.revenue}</td></tr>)}</tbody></table></Section>
    <Section title="Top Destinations by Demand"><table className="table"><tbody>{['Nobu, Antigua','Jolly Harbour','Dickenson Bay','Miami Beach'].map((d,i)=><tr key={d}><td>{i+1}</td><td>{d}</td><td>{2845-i*331}</td></tr>)}</tbody></table></Section>
    <Section title="Bottom Operators by Cancellation Rate"><table className="table"><tbody>{['Speedy Cars','On Time Shuttle','Island Express','Coastal Rides'].map((d,i)=><tr key={d}><td>{i+1}</td><td>{d}</td><td>{(6.7-i*.7).toFixed(1)}%</td></tr>)}</tbody></table></Section>
  </div>
  <Section title="Today (Live)" className="" action={<Link className="btn secondary" href="/admin/live-operations">Go to Live Operations</Link>}><div className="grid-4"><div className="mini-metric"><small>Total Journeys</small><strong>128</strong></div><div className="mini-metric"><small>Confirmed</small><strong>114</strong></div><div className="mini-metric"><small>Revenue</small><strong>$246,750</strong></div><div className="mini-metric"><small>Commission</small><strong>$24,835</strong></div></div></Section>
</>}

export function LiveOperations(){return <>
  <div className="grid-4"><KpiCard label="Total Journeys (Today)" value="128" delta="10.3%"/><KpiCard label="Confirmed" value="114" delta="11.0%"/><KpiCard label="At Risk (T-72)" value="7"/><KpiCard label="Action Required" value="4"/></div>
  <Section title="All Journeys" action={<div className="toolbar"><select><option>All Statuses</option></select><select><option>All Vehicle Types</option></select></div>}>
    <div className="journey-list">{journeys.map(j=><Link href={`/admin/journeys/${j.id}`} className="journey-card" key={j.id}><div><Status value={j.status}/><b style={{marginTop:6}}>{j.time}</b></div><div><b>{j.route}</b><small>{j.country}</small></div><div><b>{j.vehicle}</b><small>{j.type}</small></div><div className="desktop-only"><b>{j.operator}</b><small>{j.captain}</small></div><div><b>{j.seats}</b><small>seats</small></div><div><b>{j.revenue}</b><small>{j.commission} commission</small></div><div className="desktop-only"><b>{j.load}%</b><Progress value={j.load}/></div><div>View →</div></Link>)}</div>
  </Section>
</>}
