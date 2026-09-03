// @vitest-environment jsdom
import React from 'react';
import {act as testingAct,cleanup,render,screen,waitFor,within} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,describe,expect,it,vi} from 'vitest';
import {CaptainDashboard,type CaptainDashboardActions,type CaptainDashboardLoaders} from './captain-dashboard';

const ok=(rows:any[])=>({data:rows,error:null});
const journeyA={captain_assignment_id:'assignment-a',confirmed_allocation_id:'allocation-a',route_name:'Harbour run',vehicle_name:'Pace One',operator_name:'Pace',departure_status:'confirmed',scheduled_departure_ts:'2030-01-01T12:00:00Z'};
const journeyB={captain_assignment_id:'assignment-b',confirmed_allocation_id:'allocation-b',route_name:'Mountain run',vehicle_name:'Pace Two',operator_name:'Pace',departure_status:'confirmed',scheduled_departure_ts:'2030-01-02T12:00:00Z'};
const activeJourneyA={...journeyA,actual_departure_ts:'2030-01-01T12:05:00Z'};
const completedJourneyA={...activeJourneyA,actual_arrival_ts:'2030-01-01T13:05:00Z'};
const todayDuty={
 id:'allocation-today',duty_id:'allocation-today',confirmed_allocation_id:'allocation-today',captain_assignment_id:'assignment-today',country_timezone:'UTC',
 first_scheduled_departure_ts:'2030-01-01T08:30:00Z',pickup_name:'North Pier',leg_1_departure_id:'departure-today',leg_1_name:'Today harbour duty',
 leg_1_scheduled_departure_ts:'2030-01-01T08:30:00Z',leg_1_scheduled_arrival_ts:'2030-01-01T09:30:00Z',leg_1_started_at:null,leg_1_ended_at:null,
 leg_1_completion_state:null,leg_2_departure_id:null,leg_2_name:null,leg_2_scheduled_departure_ts:null,leg_2_scheduled_arrival_ts:null,leg_2_started_at:null,
 leg_2_ended_at:null,leg_2_completion_state:null,vehicle_name:'Pace Today',operator_name:'Pace',
};
const todayParty={duty_id:'allocation-today',confirmed_allocation_id:'allocation-today',booking_id:'booking-today',lead_passenger_name:'Michelle Fairbrother',adult_count:2,child_count:0,infant_count:0,payment_status:'paid',special_requirements_present:false,unread_count:2,passengers:[]};
const openWindow=(allocationId:string)=>({confirmed_allocation_id:allocationId,messaging_window_open:true,messaging_opens_at:'2030-01-01T10:00:00Z'});
const conversation=(id:string,allocationId:string,unread=0,extra:Record<string,unknown>={})=>({id,confirmed_allocation_id:allocationId,messaging_window_open:true,unread_count:unread,...extra});
const message=(id:string,conversationId:string,text:string)=>({id,conversation_id:conversationId,sender_type:'customer',message_text:text,category:'day_of_travel',created_at:'2030-01-01T10:00:00Z'});
function deferred<T>(){let resolve!:(value:T)=>void,reject!:(reason?:unknown)=>void;const promise=new Promise<T>((yes,no)=>{resolve=yes;reject=no});return {promise,resolve,reject}}

function loaders(overrides:Partial<CaptainDashboardLoaders>={}):CaptainDashboardLoaders{return {
 journeys:async()=>ok([journeyA]),manifest:async()=>ok([]),conversations:async()=>ok([]),messages:async()=>ok([]),windows:async()=>ok([openWindow('allocation-a')]),...overrides,
}}
function actions(overrides:Partial<CaptainDashboardActions>={}):CaptainDashboardActions{return {
 markRead:vi.fn(async()=>({data:null,error:null})),broadcast:vi.fn(async()=>({data:null,error:null})),complete:vi.fn(async()=>({data:null,error:null})),openParty:vi.fn(async()=>({data:null,error:null})),reply:vi.fn(async()=>({data:null,error:null})),start:vi.fn(async()=>({data:null,error:null})),...overrides,
}}
async function openParty(){await userEvent.setup().click(await screen.findByRole('button',{name:/^Message a party/}))}
async function openAll(){await userEvent.setup().click(await screen.findByRole('button',{name:'Message all'}))}
const dutyButton=(name:string)=>screen.getByRole('button',{name:new RegExp(name)});

afterEach(()=>{cleanup();vi.restoreAllMocks()});

describe('CaptainDashboard journey messaging integration',()=>{
 it.each(['/captain','/captain?tab=unknown'])('canonicalizes an active Today tab from %s',async(path)=>{
  window.history.replaceState({},'',path);
  render(<CaptainDashboard loaders={loaders()} actions={actions()}/>);
  await userEvent.setup().click(await screen.findByRole('link',{name:'Today'}));
  expect(window.location.pathname+window.location.search).toBe('/captain?tab=today');
 });

 it('defaults invalid URL state to Today and keeps future journeys in URL-backed General',async()=>{
  window.history.replaceState({},'', '/captain?tab=unknown');
  const future={...journeyB,scheduled_departure_ts:'2099-01-02T12:00:00Z'};
  const possible={...journeyA,captain_assignment_id:'possible-a',confirmed_allocation_id:'possible-a',route_name:'Possible island duty',departure_status:'possible'};
  const history={...completedJourneyA,captain_assignment_id:'history-a',confirmed_allocation_id:'history-a',route_name:'Completed island duty'};
  const todayJourney={...journeyA,captain_assignment_id:'assignment-today',confirmed_allocation_id:'allocation-today',route_name:'Legacy today row'};
  render(<CaptainDashboard loaders={loaders({journeys:async()=>ok([future,possible,history,todayJourney]),todayDuties:async()=>ok([todayDuty]),todayManifest:async()=>ok([])} as any)} actions={actions()}/>);
  expect((await screen.findByRole('link',{name:'Today'})).getAttribute('aria-current')).toBe('page');
  expect(await screen.findByRole('heading',{name:'Today harbour duty'})).toBeTruthy();
  expect(screen.queryByText('Mountain run')).toBeNull();
  await userEvent.setup().click(screen.getByRole('link',{name:'General'}));
  expect(window.location.search).toBe('?tab=general');
  expect(await screen.findByRole('heading',{name:'Confirmed future journeys'})).toBeTruthy();
  expect(screen.getByText('Mountain run')).toBeTruthy();
  expect(screen.getByText('Possible island duty')).toBeTruthy();
  expect(screen.getByText('Completed island duty')).toBeTruthy();
  expect(screen.queryByRole('button',{name:/^(Start|End)/})).toBeNull();
  await userEvent.setup().click(screen.getByRole('link',{name:'Open in Today'}));
  expect(window.location.search).toBe('?tab=today');
  expect(screen.queryByText('Mountain run')).toBeNull();
  window.history.back();
  await waitFor(()=>expect(screen.getByRole('link',{name:'General'}).getAttribute('aria-current')).toBe('page'));
  expect(screen.getByText('Mountain run')).toBeTruthy();
  window.history.forward();
  await waitFor(()=>expect(screen.getByRole('link',{name:'Today'}).getAttribute('aria-current')).toBe('page'));
  expect(screen.queryByText('Mountain run')).toBeNull();
 });

 it('waits for protected conversations and preserves the exact manifest party intent',async()=>{
  window.history.replaceState({},'', '/captain');
  const pending=deferred<{data:any[];error:any}>();
  render(<CaptainDashboard loaders={loaders({journeys:async()=>ok([]),conversations:()=>pending.promise,messages:async()=>ok([message('message-today','party-today','Deferred exact party')]),todayDuties:async()=>ok([todayDuty]),todayManifest:async()=>ok([todayParty])} as any)} actions={actions()}/>);
  const user=userEvent.setup();await user.click(await screen.findByRole('button',{name:/Michelle Fairbrother/}));await user.click(within(screen.getByRole('region',{name:'Manifest'})).getByRole('button',{name:'Message a party'}));
  expect(within(screen.getByRole('region',{name:'Communications'})).getByRole('status').textContent).toContain('Loading private party conversations');
  expect(screen.queryByText(/No private party conversations yet/)).toBeNull();
  await testingAct(async()=>pending.resolve(ok([conversation('wrong-party','wrong-allocation',0,{booking_id:'booking-today'}),conversation('party-today','allocation-today',0,{booking_id:'booking-today'})])));
  expect(await screen.findByText('Deferred exact party')).toBeTruthy();
 });

 it('retries a failed conversation load and opens the preserved exact manifest party intent',async()=>{
  window.history.replaceState({},'', '/captain');
  const conversationLoader=vi.fn().mockResolvedValueOnce({data:[],error:new Error('Private conversations unavailable')}).mockResolvedValue(ok([conversation('wrong-party','wrong-allocation',0,{booking_id:'booking-today'}),conversation('party-today','allocation-today',0,{booking_id:'booking-today'})]));
  render(<CaptainDashboard loaders={loaders({journeys:async()=>ok([]),conversations:conversationLoader,messages:async()=>ok([message('message-today','party-today','Recovered exact party')]),todayDuties:async()=>ok([todayDuty]),todayManifest:async()=>ok([todayParty])} as any)} actions={actions()}/>);
  const user=userEvent.setup();await user.click(await screen.findByRole('button',{name:/Michelle Fairbrother/}));await user.click(within(screen.getByRole('region',{name:'Manifest'})).getByRole('button',{name:'Message a party'}));
  const communications=screen.getByRole('region',{name:'Communications'});
  expect(within(communications).getByRole('alert').textContent).toContain('Private conversations unavailable');
  expect(within(communications).queryByText(/No private party conversations yet/)).toBeNull();
  await user.click(within(communications).getByRole('button',{name:'Retry private conversations'}));
  expect(await screen.findByText('Recovered exact party')).toBeTruthy();
  expect(conversationLoader).toHaveBeenCalledTimes(2);
 });

 it('lets the captain start a private thread for a manifest party with no conversation',async()=>{
  window.history.replaceState({},'', '/captain');
  let created=false;
  const openPartyAction=vi.fn(async()=>{created=true;return {data:'party-today',error:null}});
  const conversationLoader=vi.fn(async()=>ok(created?[conversation('party-today','allocation-today',0,{booking_id:'booking-today'})]:[]));
  const messageLoader=vi.fn(async()=>ok(created?[message('captain-first-message','party-today','Meet beside the blue sign')]:[]));
  render(<CaptainDashboard loaders={loaders({journeys:async()=>ok([]),conversations:conversationLoader,messages:messageLoader,windows:async()=>ok([openWindow('allocation-today')]),todayDuties:async()=>ok([todayDuty]),todayManifest:async()=>ok([todayParty])} as any)} actions={actions({openParty:openPartyAction})}/>);
  const user=userEvent.setup();
  await user.click(await screen.findByRole('button',{name:/Michelle Fairbrother/}));
  await user.click(within(screen.getByRole('region',{name:'Manifest'})).getByRole('button',{name:'Message a party'}));
  expect(await screen.findByText(/No private messages yet/)).toBeTruthy();
  await user.type(screen.getByLabelText('Message'),'Meet beside the blue sign');
  await user.click(screen.getByRole('button',{name:'Start private conversation'}));
  await waitFor(()=>expect(openPartyAction).toHaveBeenCalledWith('allocation-today','booking-today','Meet beside the blue sign','operational',expect.any(String)));
  expect(await screen.findByText('Meet beside the blue sign')).toBeTruthy();
  expect(conversationLoader).toHaveBeenCalledTimes(2);
  expect(messageLoader).toHaveBeenCalledTimes(2);
 });

 it('cancels a deferred manifest party intent when the captain changes tabs',async()=>{
  window.history.replaceState({},'', '/captain');
  const pending=deferred<{data:any[];error:any}>();
  render(<CaptainDashboard loaders={loaders({journeys:async()=>ok([]),conversations:()=>pending.promise,messages:async()=>ok([message('message-today','party-today','Should remain closed')]),todayDuties:async()=>ok([todayDuty]),todayManifest:async()=>ok([todayParty])} as any)} actions={actions()}/>);
  const user=userEvent.setup();await user.click(await screen.findByRole('button',{name:/Michelle Fairbrother/}));await user.click(within(screen.getByRole('region',{name:'Manifest'})).getByRole('button',{name:'Message a party'}));
  await user.click(screen.getByRole('link',{name:'General'}));
  await testingAct(async()=>pending.resolve(ok([conversation('party-today','allocation-today',0,{booking_id:'booking-today'})])));
  await user.click(screen.getByRole('link',{name:'Today'}));
  expect(screen.queryByText('Should remain closed')).toBeNull();
 });

 it('waits for authoritative Today identities, offers retry, and never calls an overdue journey future',async()=>{
  window.history.replaceState({},'', '/captain?tab=general');
  const now=new Date('2030-06-10T12:00:00Z'),pending=deferred<{data:any[];error:any}>();
  const future={...journeyB,scheduled_departure_ts:'2030-06-11T12:00:00Z'},overdue={...journeyA,route_name:'Overdue confirmed duty',scheduled_departure_ts:'2030-06-09T12:00:00Z'},todayJourney={...journeyA,captain_assignment_id:'assignment-today',confirmed_allocation_id:'allocation-today',route_name:'Today legacy row'};
  const todayLoader=vi.fn().mockImplementationOnce(()=>pending.promise).mockResolvedValue(ok([todayDuty]));
  render(<CaptainDashboard initialTab="general" now={now} loaders={loaders({journeys:async()=>ok([future,overdue,todayJourney]),todayDuties:todayLoader,todayManifest:async()=>ok([])} as any)} actions={actions()}/>);
  expect((await screen.findByRole('status')).textContent).toContain('Loading General');
  expect(screen.queryByText('Mountain run')).toBeNull();
  await testingAct(async()=>pending.resolve({data:[],error:new Error('Today identities unavailable')}));
  expect((await screen.findByRole('alert')).textContent).toContain('Today identities unavailable');
  expect(screen.queryByText('Mountain run')).toBeNull();
  await userEvent.setup().click(screen.getByRole('button',{name:'Retry General'}));
  expect(await screen.findByText('Mountain run')).toBeTruthy();
  const futureSection=screen.getByRole('heading',{name:'Confirmed future journeys'}).closest('section')!;
  expect(within(futureSection).queryByText('Overdue confirmed duty')).toBeNull();
  expect(screen.getByRole('heading',{name:'Past journeys needing review'}).closest('section')?.textContent).toContain('Overdue confirmed duty');
 });

 it('opens the selected protected party thread and the duty-scoped broadcast composer',async()=>{
  window.history.replaceState({},'', '/captain');
  const deps=loaders({
   journeys:async()=>ok([]),
   conversations:async()=>ok([conversation('party-today','allocation-today',2,{booking_id:'booking-today'})]),
   messages:async()=>ok([message('message-today','party-today','We are by the blue gate')]),
   windows:async()=>ok([openWindow('allocation-today')]),
   todayDuties:async()=>ok([todayDuty]),todayManifest:async()=>ok([todayParty]),
  } as any);
  render(<CaptainDashboard loaders={deps} actions={actions()}/>);
  const user=userEvent.setup();
  await user.click(await screen.findByRole('button',{name:/Michelle Fairbrother/}));
  await user.click(screen.getByRole('button',{name:'Message a party'}));
  expect(await screen.findByText('We are by the blue gate')).toBeTruthy();
  expect(screen.getAllByText('Unread 2').length).toBeGreaterThan(0);
  await user.click(screen.getByRole('button',{name:'Message all'}));
  expect(screen.getByLabelText('Message to all parties')).toBeTruthy();
 });

 it('returns a typed protected Today snapshot after a leg action',async()=>{
  window.history.replaceState({},'', '/captain');
  const scheduled=new Date(),startedAt=new Date(scheduled.getTime()+1000).toISOString();
  const operating={...todayDuty,first_scheduled_departure_ts:scheduled.toISOString(),leg_1_scheduled_departure_ts:scheduled.toISOString(),leg_1_scheduled_arrival_ts:new Date(scheduled.getTime()+3600000).toISOString()};
  const started={...operating,leg_1_started_at:startedAt};
  const dutyLoader=vi.fn().mockResolvedValueOnce(ok([operating])).mockResolvedValue(ok([started])),manifestLoader=vi.fn(async()=>ok([])),startLeg=vi.fn(async()=>({data:startedAt,error:null}));
  vi.spyOn(window,'confirm').mockReturnValue(true);
  render(<CaptainDashboard loaders={loaders({journeys:async()=>ok([]),todayDuties:dutyLoader,todayManifest:manifestLoader} as any)} actions={actions({startLeg})}/>);
  await userEvent.setup().click(await screen.findByRole('button',{name:'Start Leg 1'}));
  await waitFor(()=>expect(dutyLoader).toHaveBeenCalledTimes(2));
  expect(manifestLoader).toHaveBeenCalledTimes(2);
  expect(startLeg).toHaveBeenCalledWith('departure-today');
  expect(await screen.findByText(/Actual departure/)).toBeTruthy();
 });

 it('accepts the protected Today row disappearing after an overnight final Leg 2 End',async()=>{
  window.history.replaceState({},'', '/captain');
  const scheduled=new Date(),endedAt=new Date(scheduled.getTime()+3000).toISOString();
  const paired={
   ...todayDuty,
   first_scheduled_departure_ts:new Date(scheduled.getTime()-3600000).toISOString(),
   leg_1_scheduled_departure_ts:new Date(scheduled.getTime()-3600000).toISOString(),
   leg_1_scheduled_arrival_ts:new Date(scheduled.getTime()-3000000).toISOString(),
   leg_1_started_at:new Date(scheduled.getTime()-3500000).toISOString(),
   leg_1_ended_at:new Date(scheduled.getTime()-2900000).toISOString(),
   leg_1_completion_state:'normal',leg_1_notes:'',leg_1_incident_summary:null,
   leg_2_departure_id:'departure-return',leg_2_name:'Today harbour return',
   leg_2_scheduled_departure_ts:new Date(scheduled.getTime()-1800000).toISOString(),
   leg_2_scheduled_arrival_ts:new Date(scheduled.getTime()+1800000).toISOString(),
   leg_2_started_at:new Date(scheduled.getTime()-1200000).toISOString(),leg_2_ended_at:null,leg_2_completion_state:null,
   duty_state:'leg_2_in_progress'
  };
  const dutyLoader=vi.fn().mockResolvedValueOnce(ok([paired])).mockResolvedValue(ok([]));
  const endLeg=vi.fn(async()=>({data:endedAt,error:null}));
  render(<CaptainDashboard loaders={loaders({journeys:async()=>ok([]),todayDuties:dutyLoader,todayManifest:async()=>ok([])} as any)} actions={actions({endLeg})}/>);
  const user=userEvent.setup();

  await user.click(await screen.findByRole('button',{name:'End Leg 2'}));
  await user.click(screen.getByRole('button',{name:'Record end time'}));

  await waitFor(()=>expect(dutyLoader).toHaveBeenCalledTimes(2));
  expect(await screen.findByText('No duties are assigned for today.')).toBeTruthy();
  expect(screen.queryByRole('button',{name:'Refresh timing evidence'})).toBeNull();
  expect(endLeg).toHaveBeenCalledWith('departure-return','normal','','');
 });

 it('rejects an older timing refresh after a newer message refresh commits',async()=>{
  window.history.replaceState({},'', '/captain');
  const scheduled=new Date(),stale=deferred<{data:any[];error:any}>(),operating={...todayDuty,first_scheduled_departure_ts:scheduled.toISOString(),leg_1_scheduled_departure_ts:scheduled.toISOString(),leg_1_scheduled_arrival_ts:new Date(scheduled.getTime()+3600000).toISOString()},newer={...operating,vehicle_name:'Newest authoritative vehicle',leg_1_started_at:new Date(scheduled.getTime()+2000).toISOString()},older={...operating,vehicle_name:'Stale timing vehicle',leg_1_started_at:new Date(scheduled.getTime()+1000).toISOString()};
  const dutyLoader=vi.fn().mockResolvedValueOnce(ok([operating])).mockImplementationOnce(()=>stale.promise).mockResolvedValue(ok([newer]));
  vi.spyOn(window,'confirm').mockReturnValue(true);
  render(<CaptainDashboard loaders={loaders({journeys:async()=>ok([]),todayDuties:dutyLoader,todayManifest:async()=>ok([]),windows:async()=>ok([openWindow('allocation-today')])} as any)} actions={actions({startLeg:vi.fn(async()=>({data:older.leg_1_started_at,error:null}))})}/>);
  const user=userEvent.setup();await user.click(await screen.findByRole('button',{name:'Start Leg 1'}));
  await waitFor(()=>expect(dutyLoader).toHaveBeenCalledTimes(2));
  await user.click(screen.getByRole('button',{name:'Message all'}));await user.type(screen.getByLabelText('Message to all parties'),'Newer refresh');await user.click(screen.getByRole('button',{name:'Message all parties'}));
  expect(await screen.findByText(/Newest authoritative vehicle/)).toBeTruthy();
  await testingAct(async()=>stale.resolve(ok([older])));
  expect(screen.queryByText(/Stale timing vehicle/)).toBeNull();
  expect((await screen.findByRole('alert')).textContent).toContain('Today refresh was cancelled');
 });

 it('ignores stale injected loader results after newer allocation data renders',async()=>{
  const oldJourneys=deferred<{data:any[];error:any}>();
  const view=render(<CaptainDashboard loaders={loaders({journeys:()=>oldJourneys.promise})} actions={actions()}/>);
  view.rerender(<CaptainDashboard loaders={loaders({journeys:async()=>ok([journeyB]),windows:async()=>ok([openWindow('allocation-b')])})} actions={actions()}/>);
  expect((await screen.findAllByText('Mountain run')).length).toBeGreaterThan(0);
  await testingAct(async()=>oldJourneys.resolve(ok([journeyA])));
  expect(screen.getAllByText('Mountain run').length).toBeGreaterThan(0);
  expect(screen.queryByText('Harbour run')).toBeNull();
 });

 it('refreshes after a deferred private reply without overwriting a later allocation switch',async()=>{
  const pendingReply=deferred<{data:any;error:any}>();
  const conversationLoader=vi.fn(async()=>ok([conversation('party-a','allocation-a'),conversation('party-b','allocation-b')]));
  const deps=loaders({journeys:async()=>ok([journeyA,journeyB]),conversations:conversationLoader,messages:async()=>ok([message('message-a','party-a','Party A note'),message('message-b','party-b','Party B note')]),windows:async()=>ok([openWindow('allocation-a'),openWindow('allocation-b')])});
  render(<CaptainDashboard loaders={deps} actions={actions({reply:vi.fn(()=>pendingReply.promise)})}/>);
  const user=userEvent.setup();await openParty();await user.type(await screen.findByLabelText('Message'),'Replying to A');await user.click(screen.getByRole('button',{name:'Reply to party'}));
  await user.click(dutyButton('Mountain run'));await openParty();
  expect(await screen.findByText('Party B note')).toBeTruthy();
  await testingAct(async()=>pendingReply.resolve({data:null,error:null}));
  await waitFor(()=>expect(conversationLoader).toHaveBeenCalledTimes(2));
  expect(screen.getByText('Party B note')).toBeTruthy();
 });

 it('refreshes shared rows after a deferred private reply while preserving the newer party selection and draft',async()=>{
  const pendingReply=deferred<{data:any;error:any}>();
  const journeyLoader=vi.fn(async()=>ok([journeyA]));
  const manifestLoader=vi.fn(async()=>ok([]));
  const conversationLoader=vi.fn(async()=>ok([conversation('party-a','allocation-a'),conversation('party-b','allocation-a')]));
  const messageLoader=vi.fn().mockResolvedValueOnce(ok([message('message-a','party-a','Party A note'),message('message-b','party-b','Party B note')])).mockResolvedValue(ok([message('message-a','party-a','Party A note'),message('message-b','party-b','Party B note'),message('reply-a','party-a','Captain reply reached A')]));
  const windowLoader=vi.fn(async()=>ok([openWindow('allocation-a')]));
  render(<CaptainDashboard loaders={loaders({journeys:journeyLoader,manifest:manifestLoader,conversations:conversationLoader,messages:messageLoader,windows:windowLoader})} actions={actions({reply:vi.fn(()=>pendingReply.promise)})}/>);
  const user=userEvent.setup();
  await openParty();
  await user.type(await screen.findByLabelText('Message'),'Replying to A');
  await user.click(screen.getByRole('button',{name:'Reply to party'}));
  await user.click(screen.getByRole('button',{name:'Open party 2 conversation'}));
  await user.type(screen.getByLabelText('Message'),'B draft stays here');
  expect(screen.getByText('Party B note')).toBeTruthy();
  await testingAct(async()=>pendingReply.resolve({data:null,error:null}));
  await waitFor(()=>expect(messageLoader).toHaveBeenCalledTimes(2));
  expect(journeyLoader).toHaveBeenCalledTimes(2);
  expect(manifestLoader).toHaveBeenCalledTimes(2);
  expect(conversationLoader).toHaveBeenCalledTimes(2);
  expect(windowLoader).toHaveBeenCalledTimes(2);
  expect(screen.getByText('Party B note')).toBeTruthy();
  expect((screen.getByLabelText('Message') as HTMLTextAreaElement).value).toBe('B draft stays here');
  expect(screen.queryByText('Party reply completed')).toBeNull();
  await user.click(screen.getByRole('button',{name:'Open party 1 conversation'}));
  expect(await screen.findByText('Captain reply reached A')).toBeTruthy();
 });

 it.each([
  {
   label:'start',
   initialA:journeyA,
   refreshedA:activeJourneyA,
   actionName:'Start Leg 1',
   action:'start' as const,
   configureDialogs:()=>{vi.spyOn(window,'confirm').mockReturnValue(true)},
  },
  {
   label:'complete',
   initialA:activeJourneyA,
   refreshedA:completedJourneyA,
   actionName:'End Leg 1',
   action:'complete' as const,
   configureDialogs:()=>{vi.spyOn(window,'prompt').mockReturnValue('');vi.spyOn(window,'confirm').mockReturnValueOnce(true).mockReturnValueOnce(false).mockReturnValueOnce(true)},
  },
 ])('locks duty selection during a deferred legacy $label and reloads authoritative evidence',async({initialA,refreshedA,actionName,action,configureDialogs})=>{
  const pendingAction=deferred<{data:any;error:any}>();
  const journeyLoader=vi.fn().mockResolvedValueOnce(ok([initialA,journeyB])).mockResolvedValue(ok([refreshedA,journeyB]));
  configureDialogs();
  const actionKey=action==='start'?'startLeg':'endLeg';
  render(<CaptainDashboard loaders={loaders({journeys:journeyLoader,windows:async()=>ok([openWindow('allocation-a'),openWindow('allocation-b')])})} actions={actions({[actionKey]:vi.fn(()=>pendingAction.promise)})}/>);
  const user=userEvent.setup();
  await user.click(await screen.findByRole('button',{name:actionName}));
  if(action==='complete')await user.click(screen.getByRole('button',{name:'Record end time'}));
  expect((dutyButton('Mountain run') as HTMLButtonElement).disabled).toBe(true);
  await testingAct(async()=>pendingAction.resolve({data:action==='start'?refreshedA.actual_departure_ts:refreshedA.actual_arrival_ts,error:null}));
  await waitFor(()=>expect(journeyLoader).toHaveBeenCalledTimes(2));
  await waitFor(()=>expect((dutyButton('Mountain run') as HTMLButtonElement).disabled).toBe(false));
  await user.click(dutyButton('Mountain run'));
  expect(screen.getByRole('heading',{name:'Mountain run'})).toBeTruthy();
 });

 it('refreshes globally after a deferred broadcast without mutating the newer journey composer',async()=>{
  const pendingBroadcast=deferred<{data:any;error:any}>();
  const journeyLoader=vi.fn(async()=>ok([journeyA,journeyB]));
  const manifestLoader=vi.fn(async()=>ok([]));
  const conversationLoader=vi.fn(async()=>ok([]));
  const messageLoader=vi.fn(async()=>ok([]));
  const windowLoader=vi.fn(async()=>ok([openWindow('allocation-a'),openWindow('allocation-b')]));
  render(<CaptainDashboard loaders={loaders({journeys:journeyLoader,manifest:manifestLoader,conversations:conversationLoader,messages:messageLoader,windows:windowLoader})} actions={actions({broadcast:vi.fn(()=>pendingBroadcast.promise)})}/>);
  const user=userEvent.setup();
  await openAll();
  await user.type(await screen.findByLabelText('Message to all parties'),'Allocation A update');
  await user.click(screen.getByRole('button',{name:'Message all parties'}));
  await user.click(dutyButton('Mountain run'));await openAll();
  await user.type(screen.getByLabelText('Message to all parties'),'Allocation B draft');
  await testingAct(async()=>pendingBroadcast.resolve({data:null,error:null}));
  await waitFor(()=>expect(journeyLoader).toHaveBeenCalledTimes(2));
  expect(manifestLoader).toHaveBeenCalledTimes(2);
  expect(conversationLoader).toHaveBeenCalledTimes(2);
  expect(messageLoader).toHaveBeenCalledTimes(2);
  expect(windowLoader).toHaveBeenCalledTimes(2);
  expect(dutyButton('Mountain run').className).toContain('selected');
  expect((screen.getByLabelText('Message to all parties') as HTMLTextAreaElement).value).toBe('Allocation B draft');
  expect(screen.queryByText('Passenger update completed')).toBeNull();
 });

 it('does not report success or clear the newer composer when an abandoned broadcast fails',async()=>{
  const pendingBroadcast=deferred<{data:any;error:any}>();
  render(<CaptainDashboard loaders={loaders({journeys:async()=>ok([journeyA,journeyB]),windows:async()=>ok([openWindow('allocation-a'),openWindow('allocation-b')])})} actions={actions({broadcast:vi.fn(()=>pendingBroadcast.promise)})}/>);
  const user=userEvent.setup();
  await openAll();
  await user.type(await screen.findByLabelText('Message to all parties'),'Allocation A update');
  await user.click(screen.getByRole('button',{name:'Message all parties'}));
  await user.click(dutyButton('Mountain run'));await openAll();
  await user.type(screen.getByLabelText('Message to all parties'),'Allocation B draft');
  await testingAct(async()=>pendingBroadcast.resolve({data:null,error:new Error('Allocation A broadcast failed')}));
  expect(screen.queryByText('Passenger update completed')).toBeNull();
  expect((screen.getByLabelText('Message to all parties') as HTMLTextAreaElement).value).toBe('Allocation B draft');
  expect(dutyButton('Mountain run').className).toContain('selected');
 });

 it('never reuses another duty conversation, draft or failed broadcast request id',async()=>{
  const firstId='00000000-0000-4000-8000-000000000011',secondId='00000000-0000-4000-8000-000000000012';
  vi.spyOn(globalThis.crypto,'randomUUID').mockReturnValueOnce(firstId).mockReturnValueOnce(secondId);
  const broadcast=vi.fn().mockResolvedValueOnce({data:null,error:new Error('A failed')}).mockResolvedValue({data:null,error:null});
  render(<CaptainDashboard loaders={loaders({journeys:async()=>ok([journeyA,journeyB]),conversations:async()=>ok([conversation('party-a','allocation-a'),conversation('party-b','allocation-b')]),messages:async()=>ok([message('message-a','party-a','Only A'),message('message-b','party-b','Only B')]),windows:async()=>ok([openWindow('allocation-a'),openWindow('allocation-b')])})} actions={actions({broadcast})}/>);
  const user=userEvent.setup();await openParty();
  expect(await screen.findByText('Only A')).toBeTruthy();
  await user.type(screen.getByLabelText('Message'),'Private A draft');
  await openAll();await user.type(screen.getByLabelText('Message to all parties'),'Broadcast A');await user.click(screen.getByRole('button',{name:'Message all parties'}));
  expect((await screen.findByRole('alert')).textContent).toContain('A failed');
  await user.click(dutyButton('Mountain run'));await openParty();
  expect(await screen.findByText('Only B')).toBeTruthy();expect(screen.queryByText('Only A')).toBeNull();expect((screen.getByLabelText('Message') as HTMLTextAreaElement).value).toBe('');
  await openAll();expect((screen.getByLabelText('Message to all parties') as HTMLTextAreaElement).value).toBe('');
  await user.type(screen.getByLabelText('Message to all parties'),'Broadcast B');await user.click(screen.getByRole('button',{name:'Message all parties'}));
  expect(broadcast).toHaveBeenNthCalledWith(1,'allocation-a','Broadcast A','late_running',firstId);
  expect(broadcast).toHaveBeenNthCalledWith(2,'allocation-b','Broadcast B','late_running',secondId);
 });

 it('cancels an older thread mark-read result and counts unread across every party',async()=>{
  const markedA=deferred<{data:any;error:any}>(),markedB=deferred<{data:any;error:any}>();
  const conversationLoader=vi.fn(async()=>ok([conversation('party-a','allocation-a',2),conversation('party-b','allocation-a',3)]));
  const markRead=vi.fn((id:string)=>id==='party-a'?markedA.promise:markedB.promise);
  render(<CaptainDashboard loaders={loaders({conversations:conversationLoader})} actions={actions({markRead})}/>);
  await openParty();
  await waitFor(()=>expect(markRead).toHaveBeenCalledWith('party-a','captain'));
  expect(screen.getByRole('button',{name:/^Message a party/}).textContent).toContain('5 unread');
  await userEvent.setup().click(screen.getByRole('button',{name:'Open party 2 conversation'}));
  await waitFor(()=>expect(markRead).toHaveBeenCalledWith('party-b','captain'));
  await testingAct(async()=>markedA.resolve({data:null,error:null}));
  expect(conversationLoader).toHaveBeenCalledTimes(1);
  await testingAct(async()=>markedB.resolve({data:null,error:{message:'read failed'}}));
  expect(conversationLoader).toHaveBeenCalledTimes(1);
 });

 it('awaits a successful mark-read action before reloading conversation rows',async()=>{
  const marked=deferred<{data:any;error:any}>();
  const conversationLoader=vi.fn().mockResolvedValueOnce(ok([conversation('party-a','allocation-a',1)])).mockResolvedValue(ok([conversation('party-a','allocation-a',0)]));
  const markRead=vi.fn(()=>marked.promise);
  render(<CaptainDashboard loaders={loaders({conversations:conversationLoader})} actions={actions({markRead})}/>);
  await openParty();
  await waitFor(()=>expect(markRead).toHaveBeenCalledWith('party-a','captain'));
  expect(conversationLoader).toHaveBeenCalledTimes(1);
  await testingAct(async()=>marked.resolve({data:null,error:null}));
  await waitFor(()=>expect(conversationLoader).toHaveBeenCalledTimes(2));
 });

 it('renders scheduled protected state without private or broadcast send actions',async()=>{
  const scheduled={messaging_window_open:false,messaging_opens_at:'2099-01-01T10:00:00Z'};
  render(<CaptainDashboard loaders={loaders({conversations:async()=>ok([conversation('party-a','allocation-a',0,scheduled)]),windows:async()=>ok([{confirmed_allocation_id:'allocation-a',...scheduled}])})} actions={actions()}/>);
  await openParty();
  expect(await screen.findByText(/Captain messaging will open closer/i)).toBeTruthy();
  expect(screen.queryByRole('button',{name:'Reply to party'})).toBeNull();
  await openAll();
  expect(screen.queryByRole('button',{name:'Message all parties'})).toBeNull();
 });

 it('renders an existing open thread and preserves a failed private reply before a successful retry',async()=>{
  const reply=vi.fn().mockResolvedValueOnce({data:null,error:new Error('private offline')}).mockResolvedValue({data:null,error:null});
  render(<CaptainDashboard loaders={loaders({conversations:async()=>ok([conversation('party-a','allocation-a')]),messages:async()=>ok([message('message-a','party-a','Customer is at the dock')])})} actions={actions({reply})}/>);
  await openParty();
  expect(await screen.findByText('Customer is at the dock')).toBeTruthy();
  const user=userEvent.setup();await user.type(screen.getByLabelText('Message'),'Captain reply');await user.click(screen.getByRole('button',{name:'Reply to party'}));
  expect(await screen.findByText(/private offline/i)).toBeTruthy();
  expect((screen.getByLabelText('Message') as HTMLTextAreaElement).value).toBe('Captain reply');
  await user.click(screen.getByRole('button',{name:'Reply to party'}));
  await waitFor(()=>expect((screen.getByLabelText('Message') as HTMLTextAreaElement).value).toBe(''));
  expect(reply).toHaveBeenNthCalledWith(1,'party-a','Captain reply','operational');
  expect(reply).toHaveBeenNthCalledWith(2,'party-a','Captain reply','operational');
  expect(await screen.findByText('Party reply completed')).toBeTruthy();
 });

 it('retries a failed broadcast with the same request id and resets it after success',async()=>{
  const firstId='00000000-0000-4000-8000-000000000001',secondId='00000000-0000-4000-8000-000000000002';
  vi.spyOn(globalThis.crypto,'randomUUID').mockReturnValueOnce(firstId).mockReturnValueOnce(secondId);
  const broadcast=vi.fn().mockResolvedValueOnce({data:null,error:new Error('broadcast offline')}).mockResolvedValue({data:null,error:null});
  render(<CaptainDashboard loaders={loaders()} actions={actions({broadcast})}/>);
  await openAll();
  const user=userEvent.setup();await user.type(await screen.findByLabelText('Message to all parties'),'First update');await user.click(screen.getByRole('button',{name:'Message all parties'}));
  expect((await screen.findByRole('alert')).textContent).toContain('broadcast offline');
  await user.click(screen.getByRole('button',{name:'Message all parties'}));
  await waitFor(()=>expect((screen.getByLabelText('Message to all parties') as HTMLTextAreaElement).value).toBe(''));
  await user.type(screen.getByLabelText('Message to all parties'),'Second update');await user.click(screen.getByRole('button',{name:'Message all parties'}));
  expect(broadcast).toHaveBeenNthCalledWith(1,'allocation-a','First update','late_running',firstId);
  expect(broadcast).toHaveBeenNthCalledWith(2,'allocation-a','First update','late_running',firstId);
  expect(broadcast).toHaveBeenNthCalledWith(3,'allocation-a','Second update','late_running',secondId);
 });
});
