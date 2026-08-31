'use client';
import React,{useEffect,useMemo,useState} from 'react';
import {KpiCard,Section,Status} from './ui';

type Row=Record<string,any>;
export type AdminQualityDashboard={platform:Row;operators:Row[];captains:Row[];pickups:Row[];destinations:Row[]};
export type AdminQualityEvidencePage={items:Row[];total:number;offset:number;limit:number};
type LoadEvidencePage=(offset:number,limit:number)=>Promise<{data:AdminQualityEvidencePage[];error:any}>;
type Props={dashboard:AdminQualityDashboard|null;recent?:Row[];loadEvidencePage?:LoadEvidencePage;pageSize?:number;error?:string};
const EMPTY_ROWS:Row[]=[];

const value=(input:any)=>input===null||input===undefined||input===''?'—':Number.isFinite(Number(input))?Number(input).toFixed(2):String(input);
const trend=(input:any)=>input===null||input===undefined||input===''?'Not enough responses':`${Number(input)>=0?'↑':'↓'} ${Math.abs(Number(input)).toFixed(2)} vs prior 30 days`;
const date=(input:any)=>input?new Date(input).toLocaleDateString():'—';
const low=(row:Row)=>['booking_experience_rating','pace_shuttles_nps_score','operator_rating','captain_rating','pickup_rating','destination_rating'].some(field=>row[field]!==null&&row[field]!==undefined&&row[field]!==''&&Number(row[field])<=2);

function EvidenceComments({items}:{items:Row[]}){
 return <div className="quality-evidence-comments">{items.map(item=><div key={item.id} className="quality-evidence-comment"><span>{item.went_well||'—'}</span><span>{item.could_improve||'—'}</span><small>{item.route_name||'Journey feedback'} · {date(item.created_at)}</small></div>)}{!items.length?<span>—</span>:null}</div>;
}

function Dimension({title,rows,empty,evidence,country=false}:{title:string;rows:Row[];empty:string;evidence:Map<string,Row[]>;country?:boolean}){
 return <Section title={title}><p className="data-note">Authoritative uncapped aggregates: average, response count and 30-day trend{country?', with country comparison':''}. Recent evidence is from the single paged report below.</p><div className="table-scroll"><table className="table quality-table"><thead><tr><th>Name</th><th>Average</th><th>Response count</th><th>Trend</th>{country?<th>Country comparison</th>:null}<th>Recent evidence / comments</th></tr></thead><tbody>{rows.map(row=><tr key={row.id}><td><b>{row.name}</b></td><td>{value(row.average)}/5</td><td>{row.response_count}</td><td>{trend(row.trend)}</td>{country?<td>{row.country_name||'Country'}: {value(row.country_average)}/5</td>:null}<td><EvidenceComments items={evidence.get(String(row.id))||EMPTY_ROWS}/></td></tr>)}{!rows.length?<tr><td className="empty-state" colSpan={country?6:5}>{empty}</td></tr>:null}</tbody></table></div></Section>;
}

export function AdminQualityPerformance({dashboard,recent=EMPTY_ROWS,loadEvidencePage,pageSize=10,error}:Props){
 const [offset,setOffset]=useState(0);
 const [page,setPage]=useState<AdminQualityEvidencePage>({items:recent,total:recent.length,offset:0,limit:pageSize});
 const [loading,setLoading]=useState(!!loadEvidencePage);
 const [pageError,setPageError]=useState('');
 useEffect(()=>{
  if(!loadEvidencePage)return;
  let active=true;
  setLoading(true);setPageError('');
  void loadEvidencePage(offset,pageSize).then(result=>{
   if(!active)return;
   if(result.error){setPageError(result.error.message||String(result.error));return;}
   const next=result.data[0];
   if(!next){setPageError('Recent quality evidence did not return a page.');return;}
   setPage(next);
  }).catch(reason=>{if(active)setPageError(reason instanceof Error?reason.message:'Recent quality evidence could not be loaded.')}).finally(()=>{if(active)setLoading(false)});
  return()=>{active=false};
 },[loadEvidencePage,offset,pageSize]);

 const current=page.items;
 const evidence=useMemo(()=>{
  const grouped={operator:new Map<string,Row[]>(),captain:new Map<string,Row[]>(),pickup:new Map<string,Row[]>(),destination:new Map<string,Row[]>()};
  for(const item of current)for(const dimension of Object.keys(grouped) as Array<keyof typeof grouped>){const id=item[`${dimension}_id`];if(id)grouped[dimension].set(String(id),[...(grouped[dimension].get(String(id))||EMPTY_ROWS),item]);}
  return grouped;
 },[current]);

 if(error)return <p className="action-error" role="alert">{error}</p>;
 if(!dashboard)return <p className="action-error" role="alert">Authoritative quality report did not return data.</p>;
 const p=dashboard.platform||{},alerts=current.filter(low),start=page.total?Number(page.offset)+1:0,end=Math.min(Number(page.offset)+current.length,Number(page.total));
 return <div className="admin-quality-performance">
  <Section title="Pace Shuttles quality"><div className="grid-4"><KpiCard label="NPS" value={p.nps==null?'—':String(p.nps)}/><KpiCard label="Promoters" value={String(p.promoters||0)}/><KpiCard label="Passives" value={String(p.passives||0)}/><KpiCard label="Detractors" value={String(p.detractors||0)}/></div><div className="grid-3" style={{marginTop:12}}><div className="mini-metric"><small>Booking experience average</small><strong>{value(p.booking_experience_average)}/5</strong></div><div className="mini-metric"><small>Response count</small><strong>{p.response_count||0}</strong></div><div className="mini-metric"><small>Booking experience trend</small><strong className="metric-copy">{trend(p.trend)}</strong></div></div><div className="quality-comments"><h3>Recent comments</h3>{loading?<div className="empty-state">Loading recent quality evidence…</div>:<EvidenceComments items={current}/>} {!loading&&!pageError&&!current.length?<div className="empty-state">No recent Pace Shuttles feedback responses yet.</div>:null}{pageError?<p className="action-error" role="alert">{pageError}</p>:null}<div className="action-buttons"><button className="btn secondary" type="button" aria-label="Previous evidence page" disabled={loading||Number(page.offset)<=0} onClick={()=>setOffset(currentOffset=>Math.max(0,currentOffset-pageSize))}>Previous</button><span className="data-note">Showing {start}–{end} of {page.total}</span><button className="btn secondary" type="button" aria-label="Next evidence page" disabled={loading||Number(page.offset)+Number(page.limit)>=Number(page.total)} onClick={()=>setOffset(currentOffset=>currentOffset+pageSize)}>Next</button></div></div></Section>
  <Section title="Operator quality"><p className="data-note">Quality scores come unchanged from the protected operator quality source. The 60% operator / 40% captain evidence and attribution remain separate.</p><div className="table-scroll"><table className="table quality-table"><thead><tr><th>Operator</th><th>Quality score</th><th>Response count</th><th>Operator / captain evidence</th><th>Attribution state</th><th>Trend</th><th>Recent evidence / comments</th></tr></thead><tbody>{dashboard.operators.map(row=><tr key={row.id}><td><b>{row.name}</b></td><td>{row.quality_score??'—'}</td><td>{row.response_count}</td><td>{value(row.operator_average)}/5 · {value(row.captain_average)}/5<br/><small>60% operator / 40% captain</small></td><td>{row.attribution_states?.length?row.attribution_states.join(', '):'unassigned'}</td><td>{trend(row.trend)}</td><td><EvidenceComments items={evidence.operator.get(String(row.id))||EMPTY_ROWS}/></td></tr>)}{!dashboard.operators.length?<tr><td className="empty-state" colSpan={7}>No operators are available from the protected quality source.</td></tr>:null}</tbody></table></div></Section>
  <Dimension title="Captain performance" rows={dashboard.captains} empty="No captain performance evidence yet." evidence={evidence.captain}/><Dimension title="Pickup performance" rows={dashboard.pickups} empty="No pickup performance evidence yet." evidence={evidence.pickup} country/><Dimension title="Destination performance" rows={dashboard.destinations} empty="No destination performance evidence yet." evidence={evidence.destination} country/>
  <Section title="1–2 star review alerts"><p className="data-note">Every rating of 1 or 2 on this evidence page requires attribution review and linked journey evidence.</p>{alerts.map(row=><div className="notice bad" key={row.id}><span><b>{row.route_name||row.operator_name||'Feedback review required'}</b><br/><small><b>Went well:</b> {row.went_well||'—'}<br/><b>Could improve:</b> {row.could_improve||'—'}</small></span><span><Status value="REVIEW"/><small className="metric-detail">Attribution state: {row.attribution_state||'unassigned'}</small></span></div>)}{!pageError&&!alerts.length?<div className="empty-state">No 1–2 star review alerts on this evidence page.</div>:null}</Section>
 </div>;
}
