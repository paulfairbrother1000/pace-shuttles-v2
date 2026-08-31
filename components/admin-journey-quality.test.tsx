// @vitest-environment jsdom
import React from 'react';
import {act,cleanup,render,screen,waitFor,within} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,describe,expect,it,vi} from 'vitest';
import {AdminJourneyCommunications} from './admin-journey-communications';
import {AdminQualityPerformance} from './admin-quality-performance';

afterEach(cleanup);

describe('Site Admin journey communications',()=>{
 it('renders operational exceptions and sends a supervised reply through the supplied boundary',async()=>{
  const user=userEvent.setup();
  const onReply=vi.fn(async()=>undefined);
  render(<AdminJourneyCommunications
   alerts={[{id:'alert-1',exception_type:'t24_allocation_overdue',severity:'high',detected_at:'2030-01-01T10:00:00Z',late_minutes:18}]}
   notifications={[]}
   conversations={[{id:'conversation-1',route_name:'Heritage Quay to English Harbour',customer_name:'Customer A',status:'open',inbound_message_count:1}]}
   messages={[{id:'message-1',conversation_id:'conversation-1',sender_type:'customer',category:'day_of_travel',message_text:'Where is the captain?',created_at:'2030-01-01T10:01:00Z'}]}
   deliveries={[{id:'delivery-1',broadcast_message_id:'broadcast-1',conversation_id:'conversation-1',email_status:'failed',email_failure_reason:'Provider rejected recipient'}]}
   onReply={onReply}
  />);

  expect(screen.getByText(/t24 allocation overdue/i)).toBeTruthy();
  expect(screen.getByText('Where is the captain?')).toBeTruthy();
  expect(screen.getByText('Provider rejected recipient')).toBeTruthy();
  expect(screen.getByRole('button',{name:/Heritage Quay to English Harbour/i}).textContent).toContain('inbound 1');
  expect(screen.getByRole('button',{name:/Heritage Quay to English Harbour/i}).textContent).not.toContain('unread');
  await user.type(screen.getByLabelText('Reply as Pace Shuttles'),'The captain is approaching the pickup.');
  await user.click(screen.getByRole('button',{name:'Send supervised reply'}));
  expect(onReply).toHaveBeenCalledWith('conversation-1','The captain is approaching the pickup.','operational');
 });

 it('keeps concurrent reply pending state isolated per conversation',async()=>{
  const user=userEvent.setup();
  let resolveA:()=>void=()=>undefined,resolveB:()=>void=()=>undefined;
  const onReply=vi.fn((conversationId:string)=>new Promise<void>(resolve=>{if(conversationId==='conversation-a')resolveA=resolve;else resolveB=resolve}));
  render(<AdminJourneyCommunications alerts={[]} notifications={[]} messages={[]} deliveries={[]} onReply={onReply} conversations={[
   {id:'conversation-a',route_name:'Route A',customer_name:'Customer A',status:'open'},
   {id:'conversation-b',route_name:'Route B',customer_name:'Customer B',status:'open'},
  ]}/>);

  await user.type(screen.getByLabelText('Reply as Pace Shuttles'),'Message A');
  await user.click(screen.getByRole('button',{name:'Send supervised reply'}));
  await user.click(screen.getByRole('button',{name:/Route B/i}));
  await user.type(screen.getByLabelText('Reply as Pace Shuttles'),'Message B');
  await user.click(screen.getByRole('button',{name:'Send supervised reply'}));
  expect(onReply).toHaveBeenCalledTimes(2);

  await act(async()=>{resolveA();await Promise.resolve()});
  const pendingB=screen.getByRole('button',{name:'Sending…'}) as HTMLButtonElement;
  expect(pendingB.disabled).toBe(true);
  await user.click(pendingB);
  expect(onReply).toHaveBeenCalledTimes(2);
  await act(async()=>{resolveB();await Promise.resolve()});
 });

 it('keeps reply drafts scoped to their recipient conversation',async()=>{
  const user=userEvent.setup();
  const onReply=vi.fn(async()=>undefined);
  render(<AdminJourneyCommunications alerts={[]} notifications={[]} messages={[]} deliveries={[]} onReply={onReply} conversations={[
   {id:'conversation-a',route_name:'Route A',customer_name:'Customer A',status:'open'},
   {id:'conversation-b',route_name:'Route B',customer_name:'Customer B',status:'open'},
  ]}/>);

  await user.type(screen.getByLabelText('Reply as Pace Shuttles'),'Only for Customer A');
  await user.click(screen.getByRole('button',{name:/Route B/i}));
  expect(screen.getByText(/Replying to Customer B/i)).toBeTruthy();
  expect((screen.getByLabelText('Reply as Pace Shuttles') as HTMLTextAreaElement).value).toBe('');
  expect((screen.getByRole('button',{name:'Send supervised reply'}) as HTMLButtonElement).disabled).toBe(true);
  expect(onReply).not.toHaveBeenCalled();
 });

 it('does not double count a failed broadcast notification as a delivery failure',()=>{
  render(<AdminJourneyCommunications alerts={[]} conversations={[]} messages={[]} onReply={vi.fn()} notifications={[
   {id:'notification-1',status:'failed',template_code:'journey_broadcast',metadata:{journey_broadcast_delivery_id:'delivery-1'}},
  ]} deliveries={[{id:'delivery-1',email_status:'failed'}]}/>);
  expect(screen.getByText('Notification failures').parentElement?.textContent).toContain('1');
  expect(screen.getByText('Broadcast delivery failures').parentElement?.textContent).toContain('1');
  expect(screen.queryByText(/^Email failure$/)).toBeNull();
 });

 it('surfaces projection errors instead of rendering false empty states',()=>{
  render(<AdminJourneyCommunications alerts={[]} notifications={[]} conversations={[]} messages={[]} deliveries={[]} onReply={vi.fn()} error="Site Admin projection unavailable"/>);
  expect(screen.getByRole('alert').textContent).toContain('Site Admin projection unavailable');
  expect(screen.queryByText('No active journey communication alerts.')).toBeNull();
 });
});

describe('Site Admin quality reporting',()=>{
 it('renders authoritative separated dimensions, classification, trends, country comparison and comments',()=>{
  const dashboard={platform:{nps:20,promoters:3,passives:1,detractors:2,booking_experience_average:4.2,response_count:6,trend:0.4},operators:[{id:'operator-1',name:'Island Transit',quality_score:0.82,response_count:4,operator_average:4.1,captain_average:4.4,trend:0.2,attribution_states:['included']}],captains:[{id:'captain-1',name:'Captain A',average:4.4,response_count:3,trend:0.3}],pickups:[{id:'pickup-1',name:'Heritage Quay',average:2,response_count:2,trend:-0.5,country_name:'Antigua and Barbuda',country_average:3.7}],destinations:[{id:'destination-1',name:'English Harbour',average:4,response_count:2,trend:0.1,country_name:'Antigua and Barbuda',country_average:3.7}]};
  const recent=[{id:'feedback-1',route_name:'Heritage Quay to English Harbour',went_well:'Friendly captain.',could_improve:'Clearer pickup signs.',pickup_rating:2,created_at:'2030-01-02T10:00:00Z',attribution_state:'unassigned'}];
  render(<AdminQualityPerformance dashboard={dashboard} recent={recent}/>);

  expect(screen.getByText('Pace Shuttles quality')).toBeTruthy();
  expect(screen.getByText('Operator quality')).toBeTruthy();
  expect(screen.getByText('Captain performance')).toBeTruthy();
  expect(screen.getByText('Pickup performance')).toBeTruthy();
  expect(screen.getByText('Destination performance')).toBeTruthy();
  expect(screen.getByText('1–2 star review alerts')).toBeTruthy();
  expect(screen.getByText('Promoters').parentElement?.textContent).toContain('3');
  expect(screen.getAllByText(/Country comparison/)).toHaveLength(2);
  expect(document.body.textContent).toContain('Went well: Friendly captain.');
  expect(document.body.textContent).toContain('Could improve: Clearer pickup signs.');
  const operatorRow=screen.getByText('Island Transit').closest('tr')!;
  expect(within(operatorRow).getByText('0.82')).toBeTruthy();
 });

 it('renders every protected operator and excludes null legacy ratings from displayed aggregates',()=>{
  render(<AdminQualityPerformance dashboard={{platform:{nps:null,promoters:0,passives:0,detractors:0,booking_experience_average:null,response_count:0,trend:null},operators:[{id:'with-feedback',name:'With feedback',quality_score:0.75,response_count:1,operator_average:4,captain_average:4,trend:null,attribution_states:[]},{id:'without-feedback',name:'Without feedback',quality_score:0.91,response_count:0,operator_average:null,captain_average:null,trend:null,attribution_states:[]}],captains:[],pickups:[],destinations:[]}} recent={[]}/>);
  expect(screen.getByText('Without feedback')).toBeTruthy();
  expect(screen.getAllByText('—').length).toBeGreaterThan(0);
  expect(screen.queryByText('0.00/5')).toBeNull();
 });

 it('surfaces aggregate loader errors instead of showing empty reports',()=>{
  render(<AdminQualityPerformance dashboard={null} recent={[]} error="Authoritative quality report unavailable"/>);
  expect(screen.getByRole('alert').textContent).toContain('Authoritative quality report unavailable');
  expect(screen.queryByText('No operator quality responses yet.')).toBeNull();
 });

 it('pages one safe evidence feed and renders the second page inside each matching dimension',async()=>{
  const dashboard={platform:{nps:20,promoters:3,passives:1,detractors:2,booking_experience_average:4.2,response_count:2,trend:0.4},operators:[{id:'operator-1',name:'Island Transit',quality_score:0.82,response_count:1,operator_average:4,captain_average:5,trend:0.2,attribution_states:['included']}],captains:[{id:'captain-1',name:'Captain A',average:5,response_count:1,trend:0.3}],pickups:[{id:'pickup-1',name:'Heritage Quay',average:3,response_count:1,trend:-0.5,country_name:'Antigua and Barbuda',country_average:3.7}],destinations:[{id:'destination-1',name:'English Harbour',average:4,response_count:1,trend:0.1,country_name:'Antigua and Barbuda',country_average:3.7}]};
  const legacy={id:'feedback-legacy',route_name:'Legacy journey',operator_id:null,captain_id:null,pickup_id:null,destination_id:null,went_well:'Legacy platform comment.',could_improve:'Legacy targets unavailable.',created_at:'2030-01-03T10:00:00Z'};
  const targeted={id:'feedback-targeted',route_name:'Heritage Quay to English Harbour',operator_id:'operator-1',operator_name:'Island Transit',captain_id:'captain-1',captain_name:'Captain A',pickup_id:'pickup-1',pickup_name:'Heritage Quay',destination_id:'destination-1',destination_name:'English Harbour',went_well:'Second-page dimensional evidence.',could_improve:'Add shade.',created_at:'2030-01-02T10:00:00Z'};
  const loadEvidencePage=vi.fn(async(offset:number,limit:number)=>({data:[{items:offset===0?[legacy]:[targeted],total:2,offset,limit}],error:null}));
  const user=userEvent.setup();
  render(<AdminQualityPerformance dashboard={dashboard} recent={[]} loadEvidencePage={loadEvidencePage} pageSize={1}/>);

  expect(await screen.findByText('Legacy platform comment.')).toBeTruthy();
  expect(screen.getByText('Showing 1–1 of 2')).toBeTruthy();
  await user.click(screen.getByRole('button',{name:'Next evidence page'}));
  expect(await screen.findAllByText('Second-page dimensional evidence.')).toHaveLength(5);
  expect(screen.getByText('Showing 2–2 of 2')).toBeTruthy();
  expect(within(screen.getByText('Island Transit').closest('tr')!).getByText('Second-page dimensional evidence.')).toBeTruthy();
  expect(within(screen.getByText('Captain A').closest('tr')!).getByText('Second-page dimensional evidence.')).toBeTruthy();
  expect(within(screen.getByText('Heritage Quay').closest('tr')!).getByText('Second-page dimensional evidence.')).toBeTruthy();
  expect(within(screen.getByText('English Harbour').closest('tr')!).getByText('Second-page dimensional evidence.')).toBeTruthy();
  await waitFor(()=>expect(loadEvidencePage).toHaveBeenNthCalledWith(2,1,1));
 });

 it('surfaces evidence-page loader errors without false-empty evidence or alert states',async()=>{
  const dashboard={platform:{nps:null,promoters:0,passives:0,detractors:0,booking_experience_average:null,response_count:0,trend:null},operators:[],captains:[],pickups:[],destinations:[]};
  const loadEvidencePage=vi.fn(async()=>({data:[],error:new Error('Recent evidence unavailable')}));
  render(<AdminQualityPerformance dashboard={dashboard} loadEvidencePage={loadEvidencePage}/>);
  expect((await screen.findByRole('alert')).textContent).toContain('Recent evidence unavailable');
  expect(screen.queryByText('No recent Pace Shuttles feedback responses yet.')).toBeNull();
  expect(screen.queryByText('No 1–2 star review alerts on this evidence page.')).toBeNull();
 });
});
