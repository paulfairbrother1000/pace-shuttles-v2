'use client';

import React,{useState} from 'react';
import {requestIdForBroadcast} from '@/lib/journey-broadcast-request';

export function CaptainBroadcastComposer({allocationId,open,busy=false,onSend}:{allocationId:string;open:boolean;busy?:boolean;onSend:(message:string,category:string,requestId:string)=>Promise<void>}){
 const [message,setMessage]=useState('');
 const [category,setCategory]=useState('late_running');
 const [requestId,setRequestId]=useState('');
 const [notice,setNotice]=useState('');
 const submit=async()=>{if(!open||busy||!message.trim())return;const nextId=requestIdForBroadcast(requestId,()=>crypto.randomUUID());setRequestId(nextId);setNotice('');try{await onSend(message.trim(),category,nextId);setMessage('');setRequestId('')}catch(error:any){setNotice(error?.message||'Passenger update could not be sent. Try again.')}};
 return <div className="form-grid"><label className="form-field"><span>Update type</span><select value={category} onChange={event=>{setCategory(event.target.value);setRequestId('')}} disabled={busy||!open}><option value="late_running">Late running</option><option value="pickup_change">Pickup update</option><option value="weather">Weather / conditions</option><option value="safety">Safety update</option><option value="operational">Operational update</option></select></label><label className="form-field"><span>Message to all parties</span><textarea value={message} onChange={event=>{setMessage(event.target.value);setRequestId('')}} disabled={busy||!open} maxLength={4000} placeholder="e.g. We are running approximately 15 minutes late."/></label>{open?<button className="btn" type="button" disabled={busy||!message.trim()} onClick={()=>{void submit()}}>Message all parties</button>:null}<p className="data-note">{open?'Each party receives this update in its own private thread. Retrying a failed send preserves the same request identity.':'Party messaging is unavailable until an open journey messaging window is reported.'}</p>{notice?<p className="action-error" role="alert">{notice}</p>:null}</div>;
}
