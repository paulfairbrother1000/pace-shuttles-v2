import {describe,expect,it} from 'vitest';
import {captainDutyState,formatPartyComposition,nextLegAction,selectCurrentDuty,type CaptainTodayDuty} from './captain-today';

const now=new Date('2030-06-15T12:00:00Z');

function duty(overrides:Partial<CaptainTodayDuty>={}):CaptainTodayDuty{
 return {
  duty_id:'duty-1',confirmed_allocation_id:'allocation-1',country_timezone:'UTC',first_scheduled_departure_ts:'2030-06-15T14:00:00Z',
  leg_1_departure_id:'leg-1',leg_1_scheduled_departure_ts:'2030-06-15T14:00:00Z',
  leg_1_started_at:null,leg_1_ended_at:null,leg_1_completion_state:null,
  leg_2_departure_id:'leg-2',leg_2_scheduled_departure_ts:'2030-06-15T16:00:00Z',
  leg_2_started_at:null,leg_2_ended_at:null,leg_2_completion_state:null,
  duty_state:'ready',...overrides
 };
}

describe('captain Today presentation rules',()=>{
 it('prefers an unfinished active duty over future and completed duties',()=>{
  const later=duty({duty_id:'later',confirmed_allocation_id:'allocation-later',first_scheduled_departure_ts:'2030-06-15T15:00:00Z'});
  const active=duty({duty_id:'active',confirmed_allocation_id:'allocation-active',first_scheduled_departure_ts:'2030-06-15T13:00:00Z',leg_1_started_at:'2030-06-15T11:55:00Z',duty_state:'leg_1_in_progress'});
  const awaitingReturn=duty({duty_id:'awaiting-return',confirmed_allocation_id:'allocation-awaiting',leg_1_started_at:'2030-06-15T09:00:00Z',leg_1_ended_at:'2030-06-15T10:00:00Z',leg_1_completion_state:'normal',duty_state:'awaiting_leg_2'});
  const completed=duty({duty_id:'completed',leg_1_started_at:'2030-06-15T08:00:00Z',leg_1_ended_at:'2030-06-15T09:00:00Z',leg_1_completion_state:'normal',leg_2_departure_id:null,leg_2_scheduled_departure_ts:null,duty_state:'completed'});
  expect(selectCurrentDuty([later,awaitingReturn,active,completed],now)?.duty_id).toBe(active.duty_id);
  expect(selectCurrentDuty([later,awaitingReturn,completed],now)?.duty_id).toBe(awaitingReturn.duty_id);
  expect(selectCurrentDuty([later,awaitingReturn,completed],now)?.confirmed_allocation_id).toBe('allocation-awaiting');
 });

 it('chooses the earliest future duty, then the most recently completed duty',()=>{
  const later=duty({duty_id:'later',first_scheduled_departure_ts:'2030-06-15T16:00:00Z'});
  const sooner=duty({duty_id:'sooner',first_scheduled_departure_ts:'2030-06-15T13:00:00Z'});
  expect(selectCurrentDuty([later,sooner],now)?.duty_id).toBe('sooner');

  const first=duty({duty_id:'first',leg_1_started_at:'2030-06-15T07:00:00Z',leg_1_ended_at:'2030-06-15T08:00:00Z',leg_1_completion_state:'normal',leg_2_departure_id:null,leg_2_scheduled_departure_ts:null,duty_state:'completed'});
  const last=duty({duty_id:'last',leg_1_started_at:'2030-06-15T09:00:00Z',leg_1_ended_at:'2030-06-15T10:00:00Z',leg_1_completion_state:'normal',leg_2_departure_id:null,leg_2_scheduled_departure_ts:null,duty_state:'completed'});
  expect(selectCurrentDuty([first,last],now)?.duty_id).toBe('last');
 });

 it('uses each duty country timezone and local daylight-boundary date',()=>{
  const localToday=duty({duty_id:'kiritimati',country_timezone:'Pacific/Kiritimati',first_scheduled_departure_ts:'2030-06-15T12:30:00Z'});
  const localYesterday=duty({duty_id:'baker',country_timezone:'Etc/GMT+12',first_scheduled_departure_ts:'2030-06-15T11:30:00Z'});
  const dstBoundary=duty({duty_id:'new-york',country_timezone:'America/New_York',first_scheduled_departure_ts:'2030-06-15T03:30:00Z'});
 expect(selectCurrentDuty([localYesterday,dstBoundary,localToday],now)?.duty_id).toBe('kiritimati');
 expect(selectCurrentDuty([localYesterday,dstBoundary],now)).toBeUndefined();

  const dstNow=new Date('2030-03-10T07:00:00Z'); // 03:00, immediately after New York's DST jump
  const afterDstJump=duty({duty_id:'after-dst-jump',country_timezone:'America/New_York',first_scheduled_departure_ts:'2030-03-10T07:30:00Z'});
  expect(selectCurrentDuty([afterDstJump],dstNow)?.duty_id).toBe('after-dst-jump');
 });

 it('keeps an unfinished paired duty selected and actionable after local midnight',()=>{
  const afterMidnight=new Date('2030-06-16T01:00:00Z');
  const awaitingReturn=duty({
   duty_id:'overnight-awaiting',first_scheduled_departure_ts:'2030-06-15T22:00:00Z',
   leg_1_started_at:'2030-06-15T22:05:00Z',leg_1_ended_at:'2030-06-15T23:45:00Z',
   leg_1_completion_state:'normal',leg_2_scheduled_departure_ts:'2030-06-16T01:30:00Z',
   duty_state:'awaiting_leg_2'
  });
  const returnInProgress={...awaitingReturn,leg_2_started_at:'2030-06-16T01:35:00Z',duty_state:'leg_2_in_progress'};
  const completed={...returnInProgress,leg_2_ended_at:'2030-06-16T02:00:00Z',leg_2_completion_state:'normal',duty_state:'completed'};
  const stale={...awaitingReturn,
   leg_1_scheduled_arrival_ts:'2030-06-15T23:30:00Z',
   leg_2_scheduled_arrival_ts:'2030-06-16T03:00:00Z'
  } as CaptainTodayDuty;
  expect(selectCurrentDuty([awaitingReturn],afterMidnight)?.duty_id).toBe('overnight-awaiting');
  expect(nextLegAction(awaitingReturn,afterMidnight)).toEqual({leg:2,action:'start'});
  expect(nextLegAction(returnInProgress,afterMidnight)).toEqual({leg:2,action:'end'});
  expect(selectCurrentDuty([completed],new Date('2030-06-17T01:00:00Z'))).toBeUndefined();
  expect(selectCurrentDuty([stale],new Date('2030-06-17T03:00:01Z'))).toBeUndefined();
  expect(nextLegAction(stale,new Date('2030-06-17T03:00:01Z'))).toBeUndefined();
  expect(nextLegAction(duty({first_scheduled_departure_ts:'2030-06-14T22:00:00Z'}),afterMidnight)).toBeUndefined();
 });

 it('returns the next permissible leg action, including a one-way completion',()=>{
  const readyDuty=duty();
  const atDestinationDuty=duty({leg_1_started_at:'2030-06-15T10:00:00Z',leg_1_ended_at:'2030-06-15T11:00:00Z',leg_1_completion_state:'normal',duty_state:'awaiting_leg_2'});
  const oneWayActive=duty({leg_1_started_at:'2030-06-15T10:00:00Z',leg_2_departure_id:null,leg_2_scheduled_departure_ts:null,duty_state:'leg_1_in_progress'});
  expect(nextLegAction(readyDuty,now)).toEqual({leg:1,action:'start'});
  expect(nextLegAction(atDestinationDuty,now)).toEqual({leg:2,action:'start'});
  expect(nextLegAction(oneWayActive,now)).toEqual({leg:1,action:'end'});
 });

 it('does not offer actions for completed, incident, non-today, invalid or malformed duties',()=>{
  const completed=duty({leg_1_started_at:'2030-06-15T09:00:00Z',leg_1_ended_at:'2030-06-15T10:00:00Z',leg_1_completion_state:'normal',leg_2_departure_id:null,leg_2_scheduled_departure_ts:null,duty_state:'completed'});
  const incident=duty({leg_1_started_at:'2030-06-15T09:00:00Z',leg_1_ended_at:'2030-06-15T10:00:00Z',leg_1_completion_state:'incident',duty_state:'incident'});
  const notToday=duty({first_scheduled_departure_ts:'2030-06-16T14:00:00Z'});
  const invalid=duty({leg_2_started_at:'2030-06-15T11:00:00Z',duty_state:'leg_2_in_progress'});
  const overlappingLegs=duty({leg_1_started_at:'2030-06-15T09:00:00Z',leg_1_ended_at:'2030-06-15T10:00:00Z',leg_1_completion_state:'normal',leg_2_started_at:'2030-06-15T09:59:00Z',duty_state:'leg_2_in_progress'});
  const blankReturnLeg=duty({leg_1_started_at:'2030-06-15T09:00:00Z',leg_1_ended_at:'2030-06-15T10:00:00Z',leg_1_completion_state:'normal',leg_2_departure_id:'',leg_2_scheduled_departure_ts:null,duty_state:'awaiting_leg_2'});
  const missingOutbound=duty({leg_1_departure_id:null});
  const invalidTimezone=duty({country_timezone:'Not/A_Timezone'});
  expect(nextLegAction(completed,now)).toBeUndefined();
  expect(nextLegAction(incident,now)).toBeUndefined();
  expect(nextLegAction(notToday,now)).toBeUndefined();
  expect(nextLegAction(invalid,now)).toBeUndefined();
  expect(nextLegAction(overlappingLegs,now)).toBeUndefined();
  expect(nextLegAction(blankReturnLeg,now)).toBeUndefined();
  expect(nextLegAction(missingOutbound,now)).toBeUndefined();
  expect(nextLegAction(invalidTimezone,now)).toBeUndefined();
  expect(captainDutyState(invalid)).toBe('invalid');
  expect(captainDutyState(overlappingLegs)).toBe('invalid');
  expect(captainDutyState(blankReturnLeg)).toBe('invalid');
  expect(captainDutyState(missingOutbound)).toBe('invalid');
  expect(selectCurrentDuty([invalidTimezone],now)).toBeUndefined();
 });

 it('formats party counts with correct singular nouns and omits zero counts',()=>{
  expect(formatPartyComposition({adult_count:3,child_count:2,infant_count:1})).toBe('3 adults, 2 children, 1 infant');
  expect(formatPartyComposition({adult_count:1,child_count:1,infant_count:0})).toBe('1 adult, 1 child');
 });
});
