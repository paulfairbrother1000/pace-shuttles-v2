'use client';

import React,{useMemo,useState} from 'react';
import {KpiCard,Section,Status} from './ui';

type Row=Record<string,any>;
type Props={
 alerts:Row[];
 notifications:Row[];
 conversations:Row[];
 messages:Row[];
 deliveries:Row[];
 onReply:(conversationId:string,message:string,category:string)=>Promise<void>;
 error?:string;
};

const date=(value:any)=>value?new Date(value).toLocaleString():'—';
const label=(value:any)=>String(value||'unknown').replaceAll('_',' ');
const details=(row:Row)=>row.details&&typeof row.details==='object'?row.details:{};

function lateMinutes(alert:Row){
 const direct=Number(alert.late_minutes??details(alert).late_minutes);
 if(Number.isFinite(direct))return Math.max(0,Math.round(direct));
 const due=new Date(alert.due_at||alert.expected_at||details(alert).due_at||details(alert).expected_at||alert.detected_at).getTime();
 const end=new Date(alert.resolved_at||Date.now()).getTime();
 return Number.isFinite(due)&&Number.isFinite(end)?Math.max(0,Math.round((end-due)/60000)):0;
}

export function AdminJourneyCommunications({alerts,notifications,conversations,messages,deliveries,onReply,error}:Props){
 const [selectedId,setSelectedId]=useState<string>('');
 const [drafts,setDrafts]=useState<Record<string,string>>({});
 const [categories,setCategories]=useState<Record<string,string>>({});
 const [busyByConversation,setBusyByConversation]=useState<Record<string,boolean>>({});
 const [statuses,setStatuses]=useState<Record<string,string>>({});
 const activeAlerts=alerts.filter(alert=>!alert.resolved_at);
 const resolvedAlerts=alerts.filter(alert=>alert.resolved_at);
 const t24Overdue=activeAlerts.filter(alert=>String(alert.exception_type).includes('t24'));
 const failedNotifications=notifications.filter(row=>String(row.status).toLowerCase()==='failed');
 const failedDeliveries=deliveries.filter(row=>String(row.email_status).toLowerCase()==='failed');
 const selected=conversations.find(row=>String(row.conversation_id||row.id)===selectedId)||conversations[0];
 const selectedConversationId=String(selected?.conversation_id||selected?.id||'');
 const reply=drafts[selectedConversationId]||'',category=categories[selectedConversationId]||'operational',busy=!!busyByConversation[selectedConversationId],message=statuses[selectedConversationId]||'';
 const thread=messages.filter(row=>String(row.conversation_id)===selectedConversationId).sort((a,b)=>+new Date(a.created_at)-+new Date(b.created_at));
 const broadcasts=useMemo(()=>{
  const grouped=new Map<string,Row[]>();
  for(const delivery of deliveries){const id=String(delivery.broadcast_message_id||delivery.broadcast_source_id||'unknown');grouped.set(id,[...(grouped.get(id)||[]),delivery]);}
  return [...grouped.entries()].map(([id,rows])=>({id,rows,sent:rows.filter(row=>String(row.email_status).toLowerCase()==='sent').length,failed:rows.filter(row=>String(row.email_status).toLowerCase()==='failed').length}));
 },[deliveries]);
 const send=async()=>{
  if(!selectedConversationId||!reply.trim()||busy)return;
  setBusyByConversation(current=>({...current,[selectedConversationId]:true}));setStatuses(current=>({...current,[selectedConversationId]:''}));
  try{await onReply(selectedConversationId,reply.trim(),category);setDrafts(current=>({...current,[selectedConversationId]:''}));setStatuses(current=>({...current,[selectedConversationId]:'Reply sent as Pace Shuttles.'}));}
  catch(reason){setStatuses(current=>({...current,[selectedConversationId]:reason instanceof Error?reason.message:'Reply could not be sent.'}));}
  finally{setBusyByConversation(current=>({...current,[selectedConversationId]:false}));}
 };

 if(error)return <p className="action-error" role="alert">{error}</p>;

 return <div className="admin-communications">
  <div className="grid-4">
   <KpiCard label="Active alerts" value={String(activeAlerts.length)}/>
   <KpiCard label="T-24 details overdue" value={String(t24Overdue.length)}/>
   <KpiCard label="Notification failures" value={String(failedNotifications.length)}/>
   <KpiCard label="Broadcast delivery failures" value={String(failedDeliveries.length)}/>
   <KpiCard label="Journey conversations" value={String(conversations.length)}/>
  </div>

  <div className="grid-2" style={{marginTop:12}}>
   <Section title="Active alerts — journey communications">
    {activeAlerts.map(alert=><div className="notice bad" key={alert.id||alert.exception_key}><span><b>{label(alert.exception_type)}</b><br/><small>{alert.route_name||details(alert).route_name||'Journey exception'} · detected {date(alert.detected_at)}</small></span><span><Status value={String(alert.severity||'high').toUpperCase()}/><small className="metric-detail">Late minutes: {lateMinutes(alert)}</small></span></div>)}
    {!activeAlerts.length?<div className="empty-state">No active journey communication alerts.</div>:null}
   </Section>
   <Section title="Resolved alerts">
    {resolvedAlerts.slice(0,20).map(alert=><div className="notice" key={alert.id||alert.exception_key}><span><b>{label(alert.exception_type)}</b><br/><small>{alert.resolution_note||'Resolved by Site Admin'}</small></span><small>{date(alert.resolved_at)}<br/>Late minutes: {lateMinutes(alert)}</small></div>)}
    {!resolvedAlerts.length?<div className="empty-state">No resolved journey alerts yet.</div>:null}
   </Section>
  </div>

  <Section title="Email failure and provider status">
   <div className="table-scroll"><table className="table"><thead><tr><th>Journey / booking</th><th>Template</th><th>Provider status</th><th>Provider reference</th><th>Failure</th></tr></thead><tbody>
    {[...failedNotifications,...deliveries].slice(0,50).map((row,index)=><tr key={row.id||row.delivery_id||index}><td>{row.route_name||row.booking_id||'Journey delivery'}</td><td>{label(row.template_code||'journey broadcast')}</td><td><Status value={String(row.email_status||row.status||'unknown').toUpperCase()}/></td><td>{row.email_provider_id||row.provider_message_id||row.provider_reference||'—'}</td><td>{row.email_failure_reason||row.failure_message||row.last_error||'—'}</td></tr>)}
    {!failedNotifications.length&&!deliveries.length?<tr><td className="empty-state" colSpan={5}>No email delivery records.</td></tr>:null}
   </tbody></table></div>
  </Section>

  <div className="support-layout" style={{marginTop:12}}>
   <Section title="Journey conversations — supervision">
    {conversations.map(conversation=>{const id=String(conversation.conversation_id||conversation.id);return <button className={`support-item ${id===selectedConversationId?'selected':''}`} onClick={()=>setSelectedId(id)} key={id}><span><b>{conversation.route_name||conversation.booking_reference||'Private booking conversation'}</b><small>{conversation.customer_name||'Booking party'} · {label(conversation.status)} · inbound {conversation.inbound_message_count||0}</small></span><Status value={String(conversation.status||'open').toUpperCase()}/></button>})}
    {!conversations.length?<div className="empty-state">No journey conversations available.</div>:null}
   </Section>
   <Section title="Supervised conversation">
    {selected?<><p className="data-note">Replying to {selected.customer_name||'this booking party'} · {selected.route_name||selected.booking_reference||selectedConversationId}</p><div className="conversation-thread" aria-label="Journey conversation audit history">{thread.map(item=><article className={`message ${String(item.sender_type).toLowerCase()}`} key={item.id}><b>{label(item.sender_type)}</b><p>{item.message_text}</p><small>{label(item.category)} · {date(item.created_at)}</small></article>)}{!thread.length?<div className="empty-state">No messages in this conversation.</div>:null}</div>
     <div className="form-grid journey-admin-reply"><label className="form-field"><span>Reply category</span><select value={category} onChange={event=>setCategories(current=>({...current,[selectedConversationId]:event.target.value}))}><option value="operational">Operational</option><option value="late_running">Late running</option><option value="pickup_change">Pickup update</option><option value="safety">Safety</option></select></label><label className="form-field"><span>Reply as Pace Shuttles</span><textarea value={reply} onChange={event=>setDrafts(current=>({...current,[selectedConversationId]:event.target.value}))} maxLength={4000}/></label><button className="btn" disabled={busy||!reply.trim()} onClick={()=>void send()}>{busy?'Sending…':'Send supervised reply'}</button></div>
     {message?<p className={message.startsWith('Reply sent')?'action-success':'action-error'}>{message}</p>:null}</>:<div className="empty-state">Select a private journey conversation to supervise.</div>}
   </Section>
  </div>

  <Section title="Broadcast delivery counts">
   <div className="table-scroll"><table className="table"><thead><tr><th>Broadcast</th><th>Parties</th><th>In-app</th><th>Email sent</th><th>Email failed</th></tr></thead><tbody>{broadcasts.map(broadcast=><tr key={broadcast.id}><td>{broadcast.id.slice(0,12)}</td><td>{broadcast.rows.length}</td><td>{broadcast.rows.filter(row=>row.conversation_id).length}</td><td>{broadcast.sent}</td><td>{broadcast.failed}</td></tr>)}{!broadcasts.length?<tr><td className="empty-state" colSpan={5}>No captain broadcasts have been recorded.</td></tr>:null}</tbody></table></div>
  </Section>
 </div>;
}
