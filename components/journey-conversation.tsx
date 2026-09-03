'use client';

import React,{useState} from 'react';

export type JourneyMessage={
 id:string;
 sender_type:string;
 message_text:string;
 category:string;
 created_at:string;
};

export type JourneyConversationProps={
 mode:'customer'|'captain'|'site_admin';
 windowState:'scheduled'|'open'|'closed';
 threadId?:string;
 closesAt?:string|null;
 messages:JourneyMessage[];
 busy?:boolean;
 newThread?:boolean;
 onSend:(message:string,category:string,requestId?:string)=>Promise<void>;
};

const captainCategories=[
 ['late_running','Late running'],
 ['pickup_change','Pickup update'],
 ['weather','Weather / conditions'],
 ['safety','Safety update'],
 ['operational','Operational update'],
] as const;

const formatDate=(value:string)=>new Date(value).toLocaleString([],{weekday:'short',day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'});
const label=(value:string)=>value.replaceAll('_',' ');

export function JourneyConversation({mode,windowState,closesAt,messages,busy=false,newThread=false,onSend}:JourneyConversationProps){
 const [draft,setDraft]=useState('');
 const [category,setCategory]=useState('operational');
 const [sending,setSending]=useState(false);
 const [requestId,setRequestId]=useState('');
 const open=windowState==='open';
 const customer=mode==='customer';
 const actionLabel=customer?'Contact captain':mode==='captain'?(newThread?'Start private conversation':'Reply to party'):'Send reply';
 const stateCopy=windowState==='scheduled'
   ? 'Captain messaging will open closer to the journey.'
   : windowState==='closed'
     ? 'Conversation closed. Please contact Pace Shuttles support for further help.'
     : closesAt
       ? `Private conversation open until ${formatDate(closesAt)}.`
       : 'Private conversation open for the day of travel.';

 const submit=async()=>{
  const message=draft.trim();
  if(!message||!open||busy||sending)return;
  const stableRequestId=newThread?(requestId||crypto.randomUUID()):undefined;
  if(stableRequestId&&!requestId)setRequestId(stableRequestId);
  setSending(true);
  try{if(stableRequestId)await onSend(message,customer?'day_of_travel':category,stableRequestId);else await onSend(message,customer?'day_of_travel':category);setDraft('');setRequestId('');}
  catch{}
  finally{setSending(false);}
 };

 return <div className="journey-conversation">
   <p className={`journey-window ${windowState}`}>{stateCopy}</p>
   <div className="conversation-thread" aria-label="Private journey messages" aria-live="polite">
    {messages.map(message=><article className={`message ${String(message.sender_type).toLowerCase()}`} key={message.id}>
      <b>{label(message.sender_type)}</b>
      <p>{message.message_text}</p>
      <small>{label(message.category)} · {formatDate(message.created_at)}</small>
    </article>)}
    {messages.length===0?<div className="empty-state">No private messages yet.</div>:null}
   </div>
   {open?<form className="form-grid journey-message-form" onSubmit={event=>{event.preventDefault();void submit()}}>
     {customer?null:<label className="form-field"><span>Message category</span><select aria-label="Message category" value={category} onChange={event=>{setCategory(event.target.value);if(newThread)setRequestId('')}} disabled={busy||sending}>
       {captainCategories.map(([value,text])=><option value={value} key={value}>{text}</option>)}
     </select></label>}
     <label className="form-field"><span>Message</span><textarea aria-label="Message" value={draft} onChange={event=>{setDraft(event.target.value);if(newThread)setRequestId('')}} disabled={busy||sending} maxLength={4000} placeholder={customer?'Write a private day-of-travel message.':'Write a private operational update.'}/></label>
     <button className="btn" type="submit" disabled={!draft.trim()||busy||sending}>{sending?'Sending…':actionLabel}</button>
   </form>:null}
 </div>;
}
