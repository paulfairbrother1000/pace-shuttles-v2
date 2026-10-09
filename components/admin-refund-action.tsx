'use client';
import {useEffect,useState} from 'react';
import Link from 'next/link';
import {useSearchParams} from 'next/navigation';
import {getSupabaseBrowserClient} from '@/lib/supabase';
export function AdminRefundAction({id}:{id:string}){
 const [row,setRow]=useState<any>(null),[error,setError]=useState(''),[message,setMessage]=useState(''),[busy,setBusy]=useState(false);
 const preferred=useSearchParams().get('action');
 const load=async()=>{const s=getSupabaseBrowserClient();if(!s)return;const {data,error}=await s.rpc('v2_admin_refund_action_context',{p_refund_request_id:id});if(error)setError(error.message);else setRow(data)};
 useEffect(()=>{void load()},[id]);
 const act=async(action:'execute'|'decline')=>{
  setBusy(true);setError('');setMessage('');
  try{const s=getSupabaseBrowserClient();const session=await s?.auth.getSession();const token=session?.data.session?.access_token;
   if(!token)throw new Error('Please sign in as Site Admin');
   const response=await fetch('/api/admin/refunds',{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify({refundRequestId:id,action})});
   const result=await response.json();if(!response.ok)throw new Error(result.error||'Refund action failed');
   setMessage(result.status==='paid'?'Refund executed successfully. Stripe has accepted the refund.':result.status==='declined'?'Refund declined. No money was returned.':`Stripe refund status: ${result.status}. Check the existing refund status below; do not create another refund.`);
   await load();
  }catch(e:any){setError(e.message||'Unable to complete refund action')}finally{setBusy(false)}
 };
 if(!row)return <div className="card"><p role="status">{error||'Loading refund…'}</p></div>;
 const amount=Number(row.approved_refund_cents??row.requested_refund_cents)/100;
 const terminal=['paid','rejected','cancelled'].includes(row.status);
 return <div className="card" style={{maxWidth:800,padding:24}}><h2>Refund action</h2><p><b>{row.customer_name}</b> · {row.route_name}</p><p style={{fontSize:28,fontWeight:700}}>{row.currency} {amount.toFixed(2)}</p><p>{row.reason}</p><p>Status: <b>{row.status}</b>{row.execution?.status&&` · Stripe execution: ${row.execution.status}`}</p><p>Booking: {row.booking_id}<br/>Refund request: {id}</p>
 {!terminal&&<><p>Approve and execute returns the amount shown to the original payment method. Decline closes this refund request without returning money.</p><div className="action-buttons"><button className={preferred==='decline'?'btn secondary':'btn'} disabled={busy} onClick={()=>act('execute')}>{busy?'Processing…':row.execution?'Check / retry refund':'Approve and execute refund'}</button><button className={preferred==='decline'?'btn':'btn secondary'} disabled={busy||!!row.execution||row.status!=='requested'} onClick={()=>act('decline')}>Decline refund</button></div></>}
 {error&&<p role="alert" className="action-error">{error}</p>}{message&&<p role="status" className="action-success">{message}</p>}<p><Link href="/admin/finance">Back to all refunds</Link></p></div>;
}
