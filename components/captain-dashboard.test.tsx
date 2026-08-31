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
const openWindow=(allocationId:string)=>({confirmed_allocation_id:allocationId,messaging_window_open:true,messaging_opens_at:'2030-01-01T10:00:00Z'});
const conversation=(id:string,allocationId:string,unread=0,extra:Record<string,unknown>={})=>({id,confirmed_allocation_id:allocationId,messaging_window_open:true,unread_count:unread,...extra});
const message=(id:string,conversationId:string,text:string)=>({id,conversation_id:conversationId,sender_type:'customer',message_text:text,category:'day_of_travel',created_at:'2030-01-01T10:00:00Z'});
function deferred<T>(){let resolve!:(value:T)=>void,reject!:(reason?:unknown)=>void;const promise=new Promise<T>((yes,no)=>{resolve=yes;reject=no});return {promise,resolve,reject}}

function loaders(overrides:Partial<CaptainDashboardLoaders>={}):CaptainDashboardLoaders{return {
 journeys:async()=>ok([journeyA]),manifest:async()=>ok([]),conversations:async()=>ok([]),messages:async()=>ok([]),windows:async()=>ok([openWindow('allocation-a')]),...overrides,
}}
function actions(overrides:Partial<CaptainDashboardActions>={}):CaptainDashboardActions{return {
 markRead:vi.fn(async()=>({data:null,error:null})),broadcast:vi.fn(async()=>({data:null,error:null})),complete:vi.fn(async()=>({data:null,error:null})),reply:vi.fn(async()=>({data:null,error:null})),start:vi.fn(async()=>({data:null,error:null})),...overrides,
}}

afterEach(()=>{cleanup();vi.restoreAllMocks()});

describe('CaptainDashboard journey messaging integration',()=>{
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
  const user=userEvent.setup();await user.type(await screen.findByLabelText('Message'),'Replying to A');await user.click(screen.getByRole('button',{name:'Reply to party'}));
  await user.click(screen.getByText('Mountain run').closest('button')!);
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
   actionName:'Start journey',
   action:'start' as const,
   configureDialogs:()=>{vi.spyOn(window,'confirm').mockReturnValue(true)},
  },
  {
   label:'complete',
   initialA:activeJourneyA,
   refreshedA:completedJourneyA,
   actionName:'Complete journey',
   action:'complete' as const,
   configureDialogs:()=>{vi.spyOn(window,'prompt').mockReturnValue('');vi.spyOn(window,'confirm').mockReturnValueOnce(true).mockReturnValueOnce(false).mockReturnValueOnce(true)},
  },
 ])('refreshes journey state after a deferred $label while retaining a later journey selection',async({initialA,refreshedA,actionName,action,configureDialogs})=>{
  const pendingAction=deferred<{data:any;error:any}>();
  const journeyLoader=vi.fn().mockResolvedValueOnce(ok([initialA,journeyB])).mockResolvedValue(ok([refreshedA,journeyB]));
  configureDialogs();
  render(<CaptainDashboard loaders={loaders({journeys:journeyLoader,windows:async()=>ok([openWindow('allocation-a'),openWindow('allocation-b')])})} actions={actions({[action]:vi.fn(()=>pendingAction.promise)})}/>);
  const user=userEvent.setup();
  await user.click(await screen.findByRole('button',{name:actionName}));
  await user.click(screen.getByText('Mountain run').closest('button')!);
  await testingAct(async()=>pendingAction.resolve({data:null,error:null}));
  await waitFor(()=>expect(journeyLoader).toHaveBeenCalledTimes(2));
  const control=screen.getByRole('heading',{name:'Journey control'}).closest('section')!;
  const journeyList=screen.getByRole('heading',{name:'My journeys'}).closest('section')!;
  expect(within(control).getByText('Mountain run')).toBeTruthy();
  expect(within(journeyList).getByText('Mountain run').closest('button')?.className).toContain('selected');
  expect(screen.queryByText(new RegExp(`Journey ${action} completed`,'i'))).toBeNull();
  await user.click(screen.getByText('Harbour run').closest('button')!);
  if(action==='start'){
   expect(within(control).queryByRole('button',{name:'Start journey'})).toBeNull();
   expect(within(control).getByRole('button',{name:'Complete journey'})).toBeTruthy();
  }else{
   expect(within(control).queryByRole('button',{name:'Complete journey'})).toBeNull();
  }
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
  await user.type(await screen.findByLabelText('Message to all parties'),'Allocation A update');
  await user.click(screen.getByRole('button',{name:'Message all parties'}));
  await user.click(screen.getByText('Mountain run').closest('button')!);
  await user.type(screen.getByLabelText('Message to all parties'),'Allocation B draft');
  await testingAct(async()=>pendingBroadcast.resolve({data:null,error:null}));
  await waitFor(()=>expect(journeyLoader).toHaveBeenCalledTimes(2));
  expect(manifestLoader).toHaveBeenCalledTimes(2);
  expect(conversationLoader).toHaveBeenCalledTimes(2);
  expect(messageLoader).toHaveBeenCalledTimes(2);
  expect(windowLoader).toHaveBeenCalledTimes(2);
  const journeyList=screen.getByRole('heading',{name:'My journeys'}).closest('section')!;
  expect(within(journeyList).getByText('Mountain run').closest('button')?.className).toContain('selected');
  expect((screen.getByLabelText('Message to all parties') as HTMLTextAreaElement).value).toBe('Allocation B draft');
  expect(screen.queryByText('Passenger update completed')).toBeNull();
 });

 it('does not report success or clear the newer composer when an abandoned broadcast fails',async()=>{
  const pendingBroadcast=deferred<{data:any;error:any}>();
  render(<CaptainDashboard loaders={loaders({journeys:async()=>ok([journeyA,journeyB]),windows:async()=>ok([openWindow('allocation-a'),openWindow('allocation-b')])})} actions={actions({broadcast:vi.fn(()=>pendingBroadcast.promise)})}/>);
  const user=userEvent.setup();
  await user.type(await screen.findByLabelText('Message to all parties'),'Allocation A update');
  await user.click(screen.getByRole('button',{name:'Message all parties'}));
  await user.click(screen.getByText('Mountain run').closest('button')!);
  await user.type(screen.getByLabelText('Message to all parties'),'Allocation B draft');
  await testingAct(async()=>pendingBroadcast.resolve({data:null,error:new Error('Allocation A broadcast failed')}));
  expect(screen.queryByText('Passenger update completed')).toBeNull();
  expect((screen.getByLabelText('Message to all parties') as HTMLTextAreaElement).value).toBe('Allocation B draft');
  const journeyList=screen.getByRole('heading',{name:'My journeys'}).closest('section')!;
  expect(within(journeyList).getByText('Mountain run').closest('button')?.className).toContain('selected');
 });

 it('cancels an older thread mark-read result and counts unread across every party',async()=>{
  const markedA=deferred<{data:any;error:any}>(),markedB=deferred<{data:any;error:any}>();
  const conversationLoader=vi.fn(async()=>ok([conversation('party-a','allocation-a',2),conversation('party-b','allocation-a',3)]));
  const markRead=vi.fn((id:string)=>id==='party-a'?markedA.promise:markedB.promise);
  render(<CaptainDashboard loaders={loaders({conversations:conversationLoader})} actions={actions({markRead})}/>);
  await waitFor(()=>expect(markRead).toHaveBeenCalledWith('party-a','captain'));
  expect(screen.getByText('Unread party messages').parentElement?.textContent).toContain('5');
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
  await waitFor(()=>expect(markRead).toHaveBeenCalledWith('party-a','captain'));
  expect(conversationLoader).toHaveBeenCalledTimes(1);
  await testingAct(async()=>marked.resolve({data:null,error:null}));
  await waitFor(()=>expect(conversationLoader).toHaveBeenCalledTimes(2));
 });

 it('renders scheduled protected state without private or broadcast send actions',async()=>{
  const scheduled={messaging_window_open:false,messaging_opens_at:'2099-01-01T10:00:00Z'};
  render(<CaptainDashboard loaders={loaders({conversations:async()=>ok([conversation('party-a','allocation-a',0,scheduled)]),windows:async()=>ok([{confirmed_allocation_id:'allocation-a',...scheduled}])})} actions={actions()}/>);
  expect(await screen.findByText(/Captain messaging will open closer/i)).toBeTruthy();
  expect(screen.queryByRole('button',{name:'Reply to party'})).toBeNull();
  expect(screen.queryByRole('button',{name:'Message all parties'})).toBeNull();
 });

 it('renders an existing open thread and preserves a failed private reply before a successful retry',async()=>{
  const reply=vi.fn().mockResolvedValueOnce({data:null,error:new Error('private offline')}).mockResolvedValue({data:null,error:null});
  render(<CaptainDashboard loaders={loaders({conversations:async()=>ok([conversation('party-a','allocation-a')]),messages:async()=>ok([message('message-a','party-a','Customer is at the dock')])})} actions={actions({reply})}/>);
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
