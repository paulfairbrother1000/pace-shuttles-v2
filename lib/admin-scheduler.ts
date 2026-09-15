import {getSupabaseBrowserClient} from './supabase';
import type {SchedulerRun} from './scheduler-history';
export type SchedulerEvent={event_key:string;departure_id:string;booking_id:string;route_name:string;event_type:'t24'|'feedback';due_at:string;journey_timezone:string;execution_source:'scheduled'|'manual';executed_at:string|null;status:'pending'|'paused'|'overdue'|'processing'|'sent'|'failed';failure_reason:string|null};
export type SchedulerModel={dashboard:{control:{enabled:boolean;changed_at:string;reason?:string;next_scheduled_run_at?:string};latest_run?:SchedulerRun;recent_runs?:SchedulerRun[];audit:any[]};events:SchedulerEvent[]};
export const eventLabel=(v:string)=>v==='t24'?'T-24 journey email':v==='feedback'?'Post-travel feedback':v;
export const statusLabel=(v:string)=>v.charAt(0).toUpperCase()+v.slice(1).replaceAll('_',' ');
export const sortEvents=(rows:SchedulerEvent[])=>[...rows].sort((a,b)=>new Date(a.due_at).getTime()-new Date(b.due_at).getTime()||a.event_key.localeCompare(b.event_key));
export const formatJourneyTime=(value:string,timezone:string)=>`${new Intl.DateTimeFormat('en-GB',{dateStyle:'medium',timeStyle:'short',timeZone:timezone}).format(new Date(value))} (${timezone})`;
export const formatNextScheduledRun=(value:string)=>{
 const date=new Date(value);
 const antigua=new Intl.DateTimeFormat('en-GB',{dateStyle:'medium',timeStyle:'short',hour12:false,timeZone:'America/Antigua'}).format(date);
 const utc=new Intl.DateTimeFormat('en-GB',{dateStyle:'medium',timeStyle:'short',hour12:false,timeZone:'UTC'}).format(date);
 return `${antigua} (America/Antigua) · ${utc} UTC`;
};
export async function schedulerRequest(method='GET',body?:unknown){const client=getSupabaseBrowserClient();const session=await client?.auth.getSession();const token=session?.data.session?.access_token;if(!token)throw new Error('Sign in as Site Admin');const response=await fetch('/api/admin/scheduler',{method,headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});const data=await response.json();if(!response.ok)throw new Error(data.error||'Scheduler request failed');return data;}
