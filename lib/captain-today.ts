export type CaptainDutyState='ready'|'leg_1_in_progress'|'awaiting_leg_2'|'leg_2_in_progress'|'completed'|'incident'|'invalid';
export type CaptainLegAction={leg:1|2;action:'start'|'end'};
type Timestamp=string|Date|null|undefined;

/** The public v2_captain_today_duties projection, with optional fields for UI fixtures. */
export interface CaptainTodayDuty{
 id?:string;
 duty_id?:string;
 confirmed_allocation_id?:string;
 country_timezone:string;
 first_scheduled_departure_ts:Timestamp;
 leg_1_departure_id?:string|null;
 leg_1_scheduled_departure_ts?:Timestamp;
 leg_1_scheduled_arrival_ts?:Timestamp;
 leg_1_started_at?:Timestamp;
 leg_1_ended_at?:Timestamp;
 leg_1_completion_state?:string|null;
 leg_2_departure_id?:string|null;
 leg_2_scheduled_departure_ts?:Timestamp;
 leg_2_scheduled_arrival_ts?:Timestamp;
 leg_2_started_at?:Timestamp;
 leg_2_ended_at?:Timestamp;
 leg_2_completion_state?:string|null;
 duty_state?:string|null;
}

export interface CaptainTodayParty{
 adult_count?:number|null;
 child_count?:number|null;
 infant_count?:number|null;
}

const canonicalStates=new Set<CaptainDutyState>(['ready','leg_1_in_progress','awaiting_leg_2','leg_2_in_progress','completed','incident']);

function timestamp(value:Timestamp):number|undefined{
 if(value instanceof Date){const time=value.getTime();return Number.isNaN(time)?undefined:time;}
 if(typeof value!=='string')return undefined;
 const time=Date.parse(value);
 return Number.isNaN(time)?undefined:time;
}

function present(value:Timestamp){return value!==null&&value!==undefined;}

function completion(value:string|null|undefined){return value==='normal'||value==='incident'?value:undefined;}

function hasValidOrder(start:Timestamp,end:Timestamp){
 const started=timestamp(start),ended=timestamp(end);
 return started!==undefined&&ended!==undefined&&ended>=started;
}

function derivedDutyState(duty:CaptainTodayDuty):CaptainDutyState{
 const leg1Started=present(duty.leg_1_started_at),leg1Ended=present(duty.leg_1_ended_at),leg1Completion=completion(duty.leg_1_completion_state);
 const hasLeg1=typeof duty.leg_1_departure_id==='string'&&duty.leg_1_departure_id.trim()!=='';
 const hasLeg2=duty.leg_2_departure_id!==null&&duty.leg_2_departure_id!==undefined;
 const validLeg2Identity=!hasLeg2||(typeof duty.leg_2_departure_id==='string'&&duty.leg_2_departure_id.trim()!=='');
 const leg2Started=present(duty.leg_2_started_at),leg2Ended=present(duty.leg_2_ended_at),leg2Completion=completion(duty.leg_2_completion_state);

 if(!hasLeg1||(leg1Ended&&!leg1Started)||(leg1Completion===undefined&&present(duty.leg_1_completion_state))||(leg1Completion!==undefined&&!leg1Ended)||(leg1Started&&timestamp(duty.leg_1_started_at)===undefined)||(leg1Ended&&!hasValidOrder(duty.leg_1_started_at,duty.leg_1_ended_at)))return 'invalid';
 if(!validLeg2Identity||(!hasLeg2&&(leg2Started||leg2Ended||present(duty.leg_2_completion_state))))return 'invalid';
 if((leg2Ended&&!leg2Started)||(leg2Completion===undefined&&present(duty.leg_2_completion_state))||(leg2Completion!==undefined&&!leg2Ended)||(leg2Started&&timestamp(duty.leg_2_started_at)===undefined)||(leg2Ended&&!hasValidOrder(duty.leg_2_started_at,duty.leg_2_ended_at)))return 'invalid';
 if(leg2Started&&(!leg1Ended||leg1Completion===undefined||leg1Completion==='incident'||timestamp(duty.leg_2_started_at)!<timestamp(duty.leg_1_ended_at)!))return 'invalid';
 if(leg1Completion==='incident'||leg2Completion==='incident')return 'incident';
 if(leg2Ended)return 'completed';
 if(leg2Started)return 'leg_2_in_progress';
 if(leg1Ended)return hasLeg2?'awaiting_leg_2':'completed';
 if(leg1Started)return 'leg_1_in_progress';
 return 'ready';
}

/** Returns the canonical projected state, or invalid when the leg sequence is impossible. */
export function captainDutyState(duty:CaptainTodayDuty):CaptainDutyState{
 const derived=derivedDutyState(duty);
 if(derived==='invalid')return 'invalid';
 const projected=typeof duty.duty_state==='string'?duty.duty_state.trim().toLowerCase():'';
 if(projected==='incident')return 'incident';
 if(projected&&(!canonicalStates.has(projected as CaptainDutyState)||projected!==derived))return 'invalid';
 return derived;
}

function localDate(time:number,timezone:string):string|undefined{
 try{
  const parts=new Intl.DateTimeFormat('en-CA',{timeZone:timezone,year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date(time));
  const value=(type:string)=>parts.find(part=>part.type===type)?.value;
  const year=value('year'),month=value('month'),day=value('day');
  return year&&month&&day?`${year}-${month}-${day}`:undefined;
 }catch{return undefined;}
}

function isToday(duty:CaptainTodayDuty,now:Date){
 const scheduled=timestamp(duty.first_scheduled_departure_ts),current=now.getTime();
 if(scheduled===undefined||Number.isNaN(current))return false;
 const scheduledDate=localDate(scheduled,duty.country_timezone),currentDate=localDate(current,duty.country_timezone);
 return scheduledDate!==undefined&&currentDate!==undefined&&scheduledDate===currentDate;
}

function isOperatingDuty(duty:CaptainTodayDuty,now:Date){
 if(isToday(duty,now))return true;
 const scheduled=timestamp(duty.first_scheduled_departure_ts),started=timestamp(duty.leg_1_started_at),current=now.getTime();
 const paired=typeof duty.leg_2_departure_id==='string'&&duty.leg_2_departure_id.trim()!=='';
 const state=captainDutyState(duty);
 const outboundArrival=timestamp(duty.leg_1_scheduled_arrival_ts)??scheduled;
 const finalArrival=timestamp(duty.leg_2_scheduled_arrival_ts)??outboundArrival;
 const recoveryDeadline=Math.max(outboundArrival??Number.NEGATIVE_INFINITY,finalArrival??Number.NEGATIVE_INFINITY)+24*60*60*1000;
 return paired&&scheduled!==undefined&&started!==undefined&&!Number.isNaN(current)
  &&scheduled<current&&started<=current&&current<=recoveryDeadline
  &&(state==='leg_1_in_progress'||state==='awaiting_leg_2'||state==='leg_2_in_progress');
}

function completionTime(duty:CaptainTodayDuty){
 return timestamp(duty.leg_2_ended_at)??timestamp(duty.leg_1_ended_at);
}

/** Chooses an active duty, then the earliest future duty, then the latest duty completed today. */
export function selectCurrentDuty<T extends CaptainTodayDuty>(rows:readonly T[],now:Date):T|undefined{
 const current=now instanceof Date&&!Number.isNaN(now.getTime())?now:undefined;
 if(!current)return undefined;
 const visible=rows.filter(row=>isOperatingDuty(row,current)).map(row=>({row,state:captainDutyState(row),scheduled:timestamp(row.first_scheduled_departure_ts)!})).filter(item=>item.state!=='invalid');
 const active=visible.filter(item=>item.state==='leg_1_in_progress'||item.state==='awaiting_leg_2'||item.state==='leg_2_in_progress').sort((a,b)=>a.scheduled-b.scheduled)[0];
 if(active)return active.row;
 const future=visible.filter(item=>item.state==='ready'&&item.scheduled>current.getTime()).sort((a,b)=>a.scheduled-b.scheduled)[0];
 if(future)return future.row;
 const completed=visible.filter(item=>item.state==='completed'||item.state==='incident').map(item=>({...item,ended:completionTime(item.row)})).filter((item):item is typeof item&{ended:number}=>item.ended!==undefined&&localDate(item.ended,item.row.country_timezone)===localDate(current.getTime(),item.row.country_timezone)&&item.ended<=current.getTime()).sort((a,b)=>b.ended-a.ended)[0];
 return completed?.row;
}

/** Supplies only the next legal operation for the duty's local Today date. */
export function nextLegAction(duty:CaptainTodayDuty,now:Date):CaptainLegAction|undefined{
 if(!isOperatingDuty(duty,now))return undefined;
 switch(captainDutyState(duty)){
  case 'ready':return {leg:1,action:'start'};
  case 'leg_1_in_progress':return {leg:1,action:'end'};
  case 'awaiting_leg_2':return {leg:2,action:'start'};
  case 'leg_2_in_progress':return {leg:2,action:'end'};
  default:return undefined;
 }
}

export function formatPartyComposition(party:CaptainTodayParty):string{
 const count=(value:number|null|undefined)=>Number.isInteger(value)&&value!>0?value!:0;
 const entries:[[string,string,number],[string,string,number],[string,string,number]]=[['adult','adults',count(party.adult_count)],['child','children',count(party.child_count)],['infant','infants',count(party.infant_count)]];
 return entries.filter(([, ,value])=>value>0).map(([single,plural,value])=>`${value} ${value===1?single:plural}`).join(', ');
}
