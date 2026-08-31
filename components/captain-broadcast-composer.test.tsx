// @vitest-environment jsdom
import React from 'react';
import {render,screen} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {expect,it,vi} from 'vitest';
import {CaptainBroadcastComposer} from './captain-broadcast-composer';

it('remounts blank for allocation B and retains a failed allocation A request without an unhandled event rejection',async()=>{
 const user=userEvent.setup();const failure=vi.fn(async()=>{throw new Error('offline')});
 const view=render(<CaptainBroadcastComposer key="A" allocationId="A" open onSend={failure}/>);
 await user.type(screen.getByLabelText('Message to all parties'),'A draft');await user.click(screen.getByRole('button',{name:'Message all parties'}));
 expect((screen.getByLabelText('Message to all parties') as HTMLTextAreaElement).value).toBe('A draft');expect((await screen.findByRole('alert')).textContent).toContain('offline');
 view.rerender(<CaptainBroadcastComposer key="B" allocationId="B" open onSend={failure}/>);
 expect((screen.getByLabelText('Message to all parties') as HTMLTextAreaElement).value).toBe('');expect((screen.getByLabelText('Update type') as HTMLSelectElement).value).toBe('late_running');
});
