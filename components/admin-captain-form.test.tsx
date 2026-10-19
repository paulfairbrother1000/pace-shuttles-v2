// @vitest-environment jsdom
import React from 'react';
import {cleanup,render,screen,waitFor} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,beforeEach,describe,expect,it,vi} from 'vitest';
import {AdminCaptainForm} from './admin-captain-form';
import {adminSaveCaptain} from '@/lib/data';

vi.mock('@/lib/data',()=>({adminSaveCaptain:vi.fn()}));

const types=[{id:'heli',name:'Helicopter',active:true},{id:'boat',name:'Speed Boat',active:true}];
const setup=(props:Partial<React.ComponentProps<typeof AdminCaptainForm>>={})=>{
 const onClose=vi.fn(),onSaved=vi.fn();
 render(<AdminCaptainForm open operatorId="operator-1" vehicleTypes={types} onClose={onClose} onSaved={onSaved} {...props}/>);
 return {onClose,onSaved};
};

describe('AdminCaptainForm',()=>{
 beforeEach(()=>{vi.clearAllMocks();vi.mocked(adminSaveCaptain).mockResolvedValue({data:'captain-1',error:null} as any)});
 afterEach(()=>cleanup());

 it('saves a new captain and the operator qualification confirmation in one form',async()=>{
  const user=userEvent.setup(),{onSaved}=setup();
  await user.type(screen.getByLabelText('First name'),'Alex');
  await user.type(screen.getByLabelText('Last name'),'Pilot');
  await user.type(screen.getByLabelText('Comments',{exact:false}),'Licence verified with operator');
  await user.click(screen.getByLabelText(/Helicopter/));
  await user.click(screen.getByLabelText(/Operator confirmation/));
  await user.click(screen.getByRole('button',{name:'Add captain'}));
  await waitFor(()=>expect(adminSaveCaptain).toHaveBeenCalledWith(expect.objectContaining({
   p_captain_id:null,p_operator_id:'operator-1',p_first_name:'Alex',p_last_name:'Pilot',
   p_notes:'Licence verified with operator',p_operator_vetting_confirmed:true,p_vehicle_type_ids:['heli'],p_active:true,
  })));
  expect(onSaved).toHaveBeenCalledOnce();
 });

 it('prepopulates a captain when editing and reports save failures without closing',async()=>{
  vi.mocked(adminSaveCaptain).mockResolvedValueOnce({data:null,error:{message:'site admin required'}} as any);
  const user=userEvent.setup();
  setup({captain:{id:'captain-7',first_name:'Robin',last_name:'Pilot',email:'robin@example.com',phone:'123',notes:'Current notes',active:true,operator_vetting_confirmed:true,vehicle_type_ids:['heli']}});
  expect((screen.getByLabelText('First name') as HTMLInputElement).value).toBe('Robin');
  expect((screen.getByLabelText('Comments',{exact:false}) as HTMLTextAreaElement).value).toBe('Current notes');
  await user.click(screen.getByRole('button',{name:'Save captain'}));
  expect((await screen.findByRole('alert')).textContent).toContain('site admin required');
 });

 it('requires active captains to have a transport type and operator confirmation',async()=>{
  const user=userEvent.setup();setup();
  await user.type(screen.getByLabelText('First name'),'Alex');
  await user.type(screen.getByLabelText('Last name'),'Pilot');
  await user.click(screen.getByRole('button',{name:'Add captain'}));
  expect((await screen.findByRole('alert')).textContent).toContain('Select at least one transport type');
  expect(adminSaveCaptain).not.toHaveBeenCalled();
 });
});
