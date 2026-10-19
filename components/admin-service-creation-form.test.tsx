// @vitest-environment jsdom
import React from 'react';
import {cleanup,fireEvent,render,screen} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,describe,expect,it,vi} from 'vitest';
import {AdminServiceCreationForm} from './admin-service-creation-form';

afterEach(cleanup);

describe('AdminServiceCreationForm',()=>{
 it('lets the admin choose an existing route and submit the seasonal weekly schedule with its return pickup',async()=>{
  const user=userEvent.setup();
  const onCreate=vi.fn(async()=>{});
  render(<AdminServiceCreationForm routes={[
   {id:'outbound',route_name:'St Marys Heliport → Nobu'},
   {id:'return',route_name:'Nobu → St Marys Heliport'}
  ]} onCreate={onCreate} onCancel={()=>{}}/>);

  await user.selectOptions(screen.getByLabelText('Existing route'),'outbound');
  await user.selectOptions(screen.getByLabelText('Return route'),'return');
  await user.click(screen.getByRole('button',{name:'Create scheduled journey'}));

  expect(onCreate).toHaveBeenCalledWith(expect.objectContaining({
   route:expect.objectContaining({id:'outbound'}),
   daysOfWeek:[3],validFrom:'2026-11-01',validTo:'2027-06-30',
   departureTime:'10:00',returnEnabled:true,returnRouteId:'return',returnPickupTime:'16:00'
  }));
 });

 it('does not include inactive routes in the route picker',()=>{
  render(<AdminServiceCreationForm routes={[{id:'active',route_name:'Active route'},{id:'inactive',route_name:'Inactive route',is_active:false}]} onCreate={async()=>{}} onCancel={()=>{}}/>);
  const select=screen.getByLabelText('Existing route') as HTMLSelectElement;
  expect([...select.options].map(option=>option.textContent)).toEqual(['Choose an active route…','Active route']);
 });
});
