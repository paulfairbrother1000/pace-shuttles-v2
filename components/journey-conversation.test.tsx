// @vitest-environment jsdom
import React from 'react';
import {cleanup,render,screen} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,describe,expect,it,vi} from 'vitest';
import {JourneyConversation,type JourneyMessage} from './journey-conversation';

const messages:JourneyMessage[]=[{
 id:'message-1',sender_type:'captain_broadcast',message_text:'The pickup point is changing.',category:'pickup_change',created_at:'2030-01-01T12:00:00Z'
}];
const onSend=vi.fn(async()=>undefined);

afterEach(()=>{cleanup();onSend.mockClear()});

describe('JourneyConversation',()=>{
 it('offers the customer Contact captain action while the window is open',()=>{
  render(<JourneyConversation mode="customer" windowState="open" messages={messages} onSend={onSend}/>);
  expect(screen.getByRole('button',{name:'Contact captain'})).toBeTruthy();
  expect(screen.getByText('The pickup point is changing.')).toBeTruthy();
 });

 it('does not offer a captain reply after the conversation closes',()=>{
  render(<JourneyConversation mode="captain" windowState="closed" messages={messages} onSend={onSend}/>);
  expect(screen.getByText(/conversation closed/i)).toBeTruthy();
  expect(screen.queryByRole('button',{name:'Reply to party'})).toBeNull();
 });

 it('sends the selected approved category from a captain reply form',async()=>{
  const user=userEvent.setup();
  render(<JourneyConversation mode="captain" windowState="open" messages={[]} onSend={onSend}/>);
  await user.selectOptions(screen.getByLabelText('Message category'),'safety');
  await user.type(screen.getByLabelText('Message'), 'Please remain at the pickup point.');
  await user.click(screen.getByRole('button',{name:'Reply to party'}));
  expect(onSend).toHaveBeenCalledWith('Please remain at the pickup point.','safety');
 });

 it('clears a draft when the rendered private thread changes',async()=>{
  const user=userEvent.setup();
  const view=render(<JourneyConversation key="party-a" threadId="party-a" mode="captain" windowState="open" messages={[]} onSend={onSend}/>);
  await user.type(screen.getByLabelText('Message'),'Message for party A');
  view.rerender(<JourneyConversation key="party-b" threadId="party-b" mode="captain" windowState="open" messages={[]} onSend={onSend}/>);
  expect((screen.getByLabelText('Message') as HTMLTextAreaElement).value).toBe('');
  expect((screen.getByRole('button',{name:'Reply to party'}) as HTMLButtonElement).disabled).toBe(true);
 });

 it('retains a failed same-thread draft for retry',async()=>{
  const user=userEvent.setup();const failing=vi.fn(async()=>{throw new Error('offline')});
  render(<JourneyConversation threadId="party-a" mode="captain" windowState="open" messages={[]} onSend={failing}/>);
  await user.type(screen.getByLabelText('Message'),'Retry this');
  await user.click(screen.getByRole('button',{name:'Reply to party'}));
  expect((screen.getByLabelText('Message') as HTMLTextAreaElement).value).toBe('Retry this');
 });
});
