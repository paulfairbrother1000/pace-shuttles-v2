'use client';

import React,{useEffect,useMemo,useRef,useState} from 'react';
import {JourneyConversation,type JourneyMessage} from './journey-conversation';
import {customerOpenCaptainConversation,customerSendCaptainMessage,loadCustomerJourneyConversations,loadCustomerJourneyMessages,loadCustomerJourneyMessageWindows,markJourneyConversationRead,type DbRow} from '@/lib/data';

export type Result<T>={data:T[]|null;error:any};
export type CustomerDayOfTravelActions={
 open:(bookingId:string,message:string)=>Promise<{data:any;error:any}>;
 send:(conversationId:string,message:string)=>Promise<{data:any;error:any}>;
 markRead:(conversationId:string,audience:'customer')=>Promise<{data:any;error:any}>;
};
export type CustomerDayOfTravelLoaders={conversations:()=>Promise<Result<DbRow>>;messages:()=>Promise<Result<DbRow>>;windows:()=>Promise<Result<DbRow>>};
export const defaultCustomerDayOfTravelLoaders:CustomerDayOfTravelLoaders={conversations:loadCustomerJourneyConversations,messages:loadCustomerJourneyMessages,windows:loadCustomerJourneyMessageWindows};
export const defaultCustomerDayOfTravelActions:CustomerDayOfTravelActions={open:customerOpenCaptainConversation,send:customerSendCaptainMessage,markRead:markJourneyConversationRead};

function stateOf(row:any):'scheduled'|'open'|'closed'{return row?.messaging_window_open?'open':row?.messaging_opens_at&&new Date(row.messaging_opens_at).getTime()>Date.now()?'scheduled':'closed'}
function useRows(loader:()=>Promise<Result<DbRow>>){
 const [rows,setRows]=useState<DbRow[]>([]),[error,setError]=useState(''),[loading,setLoading]=useState(true);
 const request=useRef(0);
 const reload=async()=>{const id=++request.current;try{const result=await loader();if(id!==request.current)return;setRows(result.data||[]);setError(result.error?.message||'');setLoading(false)}catch(reason:any){if(id!==request.current)return;setRows([]);setError(reason?.message||String(reason));setLoading(false)}};
 useEffect(()=>{void reload();return()=>{request.current++}},[loader]);
 return {rows,error,loading,reload};
}

export function CustomerDayOfTravel({booking,loaders=defaultCustomerDayOfTravelLoaders,actions=defaultCustomerDayOfTravelActions}:{booking:{booking_id:string};loaders?:CustomerDayOfTravelLoaders;actions?:CustomerDayOfTravelActions}){
 const conversations=useRows(loaders.conversations),messages=useRows(loaders.messages),windows=useRows(loaders.windows);
 const [busy,setBusy]=useState(false),[notice,setNotice]=useState('');
 const operation=useRef(0),readRequest=useRef(0);
 const conversation=conversations.rows.find(row=>row.booking_id===booking.booking_id);
 const windowRow=windows.rows.find(row=>row.booking_id===booking.booking_id);
 const state=stateOf(conversation||windowRow);
 const privateMessages=useMemo(()=>conversation?messages.rows.filter(row=>row.conversation_id===conversation.id) as JourneyMessage[]:[],[conversation?.id,messages.rows]);
 useEffect(()=>()=>{operation.current++;readRequest.current++},[booking.booking_id]);
 useEffect(()=>{let live=true;if(!conversation||!Number(conversation.unread_count||0))return;const id=++readRequest.current,sendId=operation.current;void (async()=>{try{const result=await actions.markRead(conversation.id,'customer');if(live&&id===readRequest.current&&sendId===operation.current&&!result.error)await conversations.reload()}catch{}})();return()=>{live=false}},[actions,conversation?.id,conversation?.unread_count,privateMessages.length]);
 const send=async(message:string)=>{readRequest.current++;const id=++operation.current;setBusy(true);setNotice('');let result;try{result=conversation?await actions.send(conversation.id,message):await actions.open(booking.booking_id,message)}catch(reason:any){if(id===operation.current){setBusy(false);setNotice(reason?.message||String(reason))}throw reason}if(id!==operation.current)return;if(result.error){setBusy(false);setNotice(result.error.message||String(result.error));throw result.error}setNotice('Message sent to your captain.');await Promise.all([conversations.reload(),messages.reload(),windows.reload()]);if(id===operation.current)setBusy(false)};
 if(conversations.loading||messages.loading||windows.loading)return <p className="data-note">Loading private captain messaging…</p>;
 if(conversations.error||messages.error||windows.error)return <p className="action-error">{conversations.error||messages.error||windows.error} Pace Shuttles support remains available below.</p>;
 if(!conversation&&state==='scheduled')return <p className="data-note">Captain messaging is scheduled to open closer to this journey. Pace Shuttles support remains available below.</p>;
 if(!conversation&&state==='closed')return <p className="data-note">Captain messaging is closed for this booking. Pace Shuttles support remains available below.</p>;
 const identity=conversation?.id||booking.booking_id;
 return <div className="journey-day-of-travel"><h3>Day of Travel</h3><p className="data-note">This is a private conversation with your assigned captain. Journey-wide updates appear here too.</p><JourneyConversation key={identity} threadId={identity} mode="customer" windowState={state} closesAt={(conversation||windowRow)?.messaging_closes_at} messages={privateMessages} busy={busy} onSend={(message)=>send(message)}/>{notice?<p className={notice.includes('sent')?'action-success':'action-error'}>{notice}</p>:null}</div>;
}
