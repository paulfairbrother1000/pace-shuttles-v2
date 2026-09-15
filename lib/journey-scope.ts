export type AdminJourneyScope='operational'|'past_closed';

export const TERMINAL_JOURNEY_STATUSES=['completed','cancelled','closed_unrecorded'] as const;

export function journeyScopeSpec(scope:AdminJourneyScope,now=new Date()){
 if(scope==='past_closed')return {
  includedStatuses:[...TERMINAL_JOURNEY_STATUSES],
  before:now.toISOString(),
  ascending:false,
 };
 return {
  excludedStatuses:[...TERMINAL_JOURNEY_STATUSES],
  since:new Date(now.getTime()-32*60*60*1000).toISOString(),
  ascending:true,
 };
}
