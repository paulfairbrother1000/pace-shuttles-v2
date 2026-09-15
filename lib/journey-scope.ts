export type AdminJourneyScope='operational'|'today'|'next_7_days'|'past_closed';

export const TERMINAL_JOURNEY_STATUSES=['completed','cancelled','closed_unrecorded'] as const;

const ANTIGUA_OFFSET_MS=4*60*60*1000;
function antiguaDayStart(now:Date){
 const local=new Date(now.getTime()-ANTIGUA_OFFSET_MS);
 return new Date(Date.UTC(local.getUTCFullYear(),local.getUTCMonth(),local.getUTCDate())+ANTIGUA_OFFSET_MS);
}

export function journeyScopeSpec(scope:AdminJourneyScope,now=new Date()){
 const today=antiguaDayStart(now),tomorrow=new Date(today.getTime()+86400000),nextWeek=new Date(today.getTime()+7*86400000);
 if(scope==='past_closed')return {
  includedStatuses:[...TERMINAL_JOURNEY_STATUSES],
  before:today.toISOString(),
  ascending:false,
 };
 if(scope==='today')return {since:today.toISOString(),before:tomorrow.toISOString(),ascending:true};
 if(scope==='next_7_days')return {since:today.toISOString(),before:nextWeek.toISOString(),ascending:true};
 return {
  since:today.toISOString(),
  ascending:true,
 };
}
