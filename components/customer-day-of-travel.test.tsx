// @vitest-environment jsdom
import React from 'react';
import {act as testingAct,cleanup,render,screen,waitFor} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,describe,expect,it,vi} from 'vitest';
import {CustomerDayOfTravel,type CustomerDayOfTravelActions,type CustomerDayOfTravelLoaders} from './customer-day-of-travel';

const ok=(data:any[])=>({data,error:null});
const loaders=(windows:any[],error:any=null):CustomerDayOfTravelLoaders=>({conversations:async()=>ok([]),messages:async()=>ok([]),windows:async()=>error?{data:null,error}:ok(windows)});
const actions=(overrides:Partial<CustomerDayOfTravelActions>={}):CustomerDayOfTravelActions=>({open:vi.fn(async()=>({data:{},error:null})),send:vi.fn(async()=>({data:{},error:null})),markRead:vi.fn(async()=>({data:{},error:null})),...overrides});
function deferred<T>(){let resolve!:(value:T)=>void,reject!:(reason?:unknown)=>void;const promise=new Promise<T>((yes,no)=>{resolve=yes;reject=no});return {promise,resolve,reject}}
afterEach(()=>cleanup());

describe('CustomerDayOfTravel',()=>{
 it('opens a first private contact only in the protected open window',async()=>{
  const act=actions();render(<CustomerDayOfTravel booking={{booking_id:'booking-a'}} loaders={loaders([{booking_id:'booking-a',messaging_window_open:true}])} actions={act}/>);
  await userEvent.setup().type(await screen.findByLabelText('Message'),'At the dock');
  await userEvent.setup().click(screen.getByRole('button',{name:'Contact captain'}));
  expect(act.open).toHaveBeenCalledWith('booking-a','At the dock');
 });
 it('shows scheduled, closed, and loader-error fallback without exposing a contact action',async()=>{
  const view=render(<CustomerDayOfTravel booking={{booking_id:'booking-a'}} loaders={loaders([{booking_id:'booking-a',messaging_opens_at:'2099-01-01T00:00:00Z'}])} actions={actions()}/>);
  expect(await screen.findByText(/scheduled to open/i)).toBeTruthy();expect(screen.queryByRole('button',{name:'Contact captain'})).toBeNull();
  view.rerender(<CustomerDayOfTravel booking={{booking_id:'booking-b'}} loaders={loaders([{booking_id:'booking-b',messaging_opens_at:'2020-01-01T00:00:00Z'}])} actions={actions()}/>);
  expect(await screen.findByText(/messaging is closed/i)).toBeTruthy();
  view.rerender(<CustomerDayOfTravel booking={{booking_id:'booking-c'}} loaders={loaders([],new Error('projection unavailable'))} actions={actions()}/>);
  expect(await screen.findByText(/projection unavailable/i)).toBeTruthy();
 });
 it('retains a failed first-contact draft',async()=>{
  const act=actions({open:vi.fn(async()=>({data:null,error:new Error('offline')}))});render(<CustomerDayOfTravel booking={{booking_id:'booking-a'}} loaders={loaders([{booking_id:'booking-a',messaging_window_open:true}])} actions={act}/>);
 const user=userEvent.setup();await user.type(await screen.findByLabelText('Message'),'Retry me');await user.click(screen.getByRole('button',{name:'Contact captain'}));
  expect((screen.getByLabelText('Message') as HTMLTextAreaElement).value).toBe('Retry me');expect(await screen.findByText(/offline/i)).toBeTruthy();
 });

 it('renders and sends within an existing conversation, then shows reloaded messages',async()=>{
  const conversation={id:'conversation-a',booking_id:'booking-a',messaging_window_open:true,unread_count:0};
  const conversationLoader=vi.fn(async()=>ok([conversation]));
  const messageLoader=vi.fn()
   .mockResolvedValueOnce(ok([{id:'message-a',conversation_id:'conversation-a',sender_type:'captain',message_text:'Meet beside bay 4',category:'operational',created_at:'2030-01-01T10:00:00Z'}]))
   .mockResolvedValue(ok([{id:'message-b',conversation_id:'conversation-a',sender_type:'customer',message_text:'I am beside bay 4',category:'day_of_travel',created_at:'2030-01-01T10:01:00Z'}]));
  const act=actions();
  render(<CustomerDayOfTravel booking={{booking_id:'booking-a'}} loaders={{conversations:conversationLoader,messages:messageLoader,windows:async()=>ok([])}} actions={act}/>);
  expect(await screen.findByText('Meet beside bay 4')).toBeTruthy();
  const user=userEvent.setup();await user.type(screen.getByLabelText('Message'),'I am here');await user.click(screen.getByRole('button',{name:'Contact captain'}));
  expect(act.send).toHaveBeenCalledWith('conversation-a','I am here');
  expect(await screen.findByText('I am beside bay 4')).toBeTruthy();
 });

 it('awaits mark-read before reloading the protected conversation rows',async()=>{
  const marked=deferred<{data:any;error:any}>();
  const conversationLoader=vi.fn()
   .mockResolvedValueOnce(ok([{id:'conversation-a',booking_id:'booking-a',messaging_window_open:true,unread_count:2}]))
   .mockResolvedValue(ok([{id:'conversation-a',booking_id:'booking-a',messaging_window_open:true,unread_count:0}]));
  const act=actions({markRead:vi.fn(()=>marked.promise)});
  render(<CustomerDayOfTravel booking={{booking_id:'booking-a'}} loaders={{conversations:conversationLoader,messages:async()=>ok([]),windows:async()=>ok([])}} actions={act}/>);
  await waitFor(()=>expect(act.markRead).toHaveBeenCalledWith('conversation-a','customer'));
  expect(conversationLoader).toHaveBeenCalledTimes(1);
  await testingAct(async()=>marked.resolve({data:null,error:null}));
  await waitFor(()=>expect(conversationLoader).toHaveBeenCalledTimes(2));
 });

 it('surfaces rejected loader and action dependencies without trapping a retry draft',async()=>{
  const rejectedLoaders:CustomerDayOfTravelLoaders={conversations:vi.fn(async()=>{throw new Error('projection rejected')}),messages:async()=>ok([]),windows:async()=>ok([])};
  const view=render(<CustomerDayOfTravel booking={{booking_id:'booking-a'}} loaders={rejectedLoaders} actions={actions()}/>);
  expect(await screen.findByText(/projection rejected/i)).toBeTruthy();

  const act=actions({open:vi.fn(async()=>{throw new Error('send rejected')})});
  view.rerender(<CustomerDayOfTravel key="booking-b" booking={{booking_id:'booking-b'}} loaders={loaders([{booking_id:'booking-b',messaging_window_open:true}])} actions={act}/>);
  const user=userEvent.setup();await user.type(await screen.findByLabelText('Message'),'Please retry this');await user.click(screen.getByRole('button',{name:'Contact captain'}));
  expect(await screen.findByText(/send rejected/i)).toBeTruthy();
  expect((screen.getByLabelText('Message') as HTMLTextAreaElement).value).toBe('Please retry this');
  expect((screen.getByLabelText('Message') as HTMLTextAreaElement).disabled).toBe(false);
 });

 it('ignores an older mark-read reload after a newer send reload has rendered',async()=>{
  const staleReload=deferred<{data:any[];error:any}>();
  const conversation={id:'conversation-a',booking_id:'booking-a',messaging_window_open:true};
  const conversationLoader=vi.fn()
   .mockResolvedValueOnce(ok([{...conversation,unread_count:1}]))
   .mockImplementationOnce(()=>staleReload.promise)
   .mockResolvedValue(ok([{...conversation,unread_count:0}]));
  const messageLoader=vi.fn()
   .mockResolvedValueOnce(ok([{id:'message-a',conversation_id:'conversation-a',sender_type:'captain',message_text:'Initial note',category:'operational',created_at:'2030-01-01T10:00:00Z'}]))
   .mockResolvedValue(ok([{id:'message-b',conversation_id:'conversation-a',sender_type:'customer',message_text:'Fresh after send',category:'day_of_travel',created_at:'2030-01-01T10:01:00Z'}]));
  const act=actions();
  render(<CustomerDayOfTravel booking={{booking_id:'booking-a'}} loaders={{conversations:conversationLoader,messages:messageLoader,windows:async()=>ok([])}} actions={act}/>);
  await waitFor(()=>expect(conversationLoader).toHaveBeenCalledTimes(2));
  const user=userEvent.setup();await user.type(screen.getByLabelText('Message'),'Sending now');await user.click(screen.getByRole('button',{name:'Contact captain'}));
  expect(await screen.findByText('Fresh after send')).toBeTruthy();
  await testingAct(async()=>staleReload.resolve(ok([])));
  expect(screen.getByText('Fresh after send')).toBeTruthy();
 });
});
