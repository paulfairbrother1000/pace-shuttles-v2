// @vitest-environment jsdom
import React from 'react';
import {cleanup,render,screen} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,describe,expect,it,vi} from 'vitest';
import {OperatorVehicleEditor} from './operator-vehicle-editor';

const vehicles=[{vehicle_id:'v1',operator_id:'o1',vehicle_type_id:'boat',vehicle_type_name:'Speed Boat',name:'Sea Sea Rider',capacity_seats:10,active:true,preferred_captain_id:'c1',preferred_captain_name:'James Williams'}];
const offers=[{offer_id:'of1',operator_id:'o1',vehicle_id:'v1',route_id:'r1',route_name:'Jolly Harbour → Nobu',service_id:'saturday',active:true,min_seats:4,max_seats:10,min_revenue_cents:140000,min_value_threshold_ratio:.8,below_minimum_operation_mode:'custom_threshold' as const,post_min_discount_enabled:true,post_min_discount_bps:1500,preferred_captain_id:'c2',preferred_captain_name:'Michelle Thomas'}];
const captains=[{operator_id:'o1',captain_id:'c1',captain_name:'James Williams',vehicle_type_id:'boat'},{operator_id:'o1',captain_id:'c2',captain_name:'Michelle Thomas',vehicle_type_id:'boat'},{operator_id:'o1',captain_id:'c3',captain_name:'Taxi Captain',vehicle_type_id:'taxi'}];
const routes=[
 {operator_id:'o1',route_id:'r1',route_name:'Jolly Harbour → Nobu',service_id:'saturday',days_of_week:[6],departure_time:'10:00:00',timezone:'America/Antigua',vehicle_type_id:'boat',country_id:'ag'},
 {operator_id:'o1',route_id:'r1',route_name:'Jolly Harbour → Nobu',service_id:'tuesday',days_of_week:[2],departure_time:'11:00:00',timezone:'America/Antigua',vehicle_type_id:'boat',country_id:'ag'},
 {operator_id:'o1',route_id:'r2',route_name:'Jolly Harbour → Boom',service_id:'boom-weekday',days_of_week:[1,2,3,4,5],departure_time:'09:00:00',timezone:'America/Antigua',vehicle_type_id:'boat',country_id:'ag'},
 {operator_id:'o1',route_id:'r3',route_name:'Airport → Town',service_id:'airport-taxi',days_of_week:[1,2,3,4,5],departure_time:'09:00:00',timezone:'America/Antigua',vehicle_type_id:'taxi',country_id:'ag'}
];
const vehicleTypes=[{operator_id:'o1',vehicle_type_id:'boat',vehicle_type_name:'Speed Boat'},{operator_id:'o1',vehicle_type_id:'taxi',vehicle_type_name:'Taxi'}];
afterEach(cleanup);

const setup=(onSave=vi.fn(async(_payload:Record<string,unknown>)=>true))=>{render(<OperatorVehicleEditor vehicles={vehicles} offers={offers} captains={captains} routes={routes} vehicleTypes={vehicleTypes} busy={false} onSave={onSave}/>);return onSave};

describe('OperatorVehicleEditor',()=>{
 it('shows the full selected vehicle and offer',()=>{
  setup();
  expect((screen.getByLabelText('Vehicle name') as HTMLInputElement).value).toBe('Sea Sea Rider');
  expect(screen.getByText('Jolly Harbour → Nobu — Saturday at 10:00')).toBeTruthy();
  expect((screen.getByLabelText('Default / preferred captain') as HTMLSelectElement).value).toBe('c1');
  expect(screen.getByText('Default captain: James Williams')).toBeTruthy();
  const routeCaptain = screen.getByLabelText('Preferred captain for Jolly Harbour → Nobu') as HTMLSelectElement;
  expect(routeCaptain.value).toBe('c2');
  expect(routeCaptain.closest('label')?.className).toContain('route-captain-field');
  expect(screen.getByRole('option',{name:'Boat default — James Williams'})).toBeTruthy();
  expect(screen.getByText('Route override — Michelle Thomas')).toBeTruthy();
 });

 it('creates a blank form and offers only unattached matching routes',async()=>{
  setup();const user=userEvent.setup();await user.click(screen.getByRole('button',{name:'+ Add vehicle'}));
  await user.selectOptions(screen.getByLabelText('Transport Type'),'boat');
  const options=Array.from((screen.getByLabelText('Eligible route') as HTMLSelectElement).options).map(option=>option.text);
  expect(options).toContain('Jolly Harbour → Nobu — Saturday at 10:00');
  expect(options).toContain('Jolly Harbour → Nobu — Tuesday at 11:00');
  expect(options).toContain('Jolly Harbour → Boom — Monday, Tuesday, Wednesday, Thursday, Friday at 09:00');
  expect(options).not.toContain('Airport → Town');
 });

 it('keeps same-route services independently selectable and attached',async()=>{
  setup();const user=userEvent.setup();
  expect(screen.getByText('Jolly Harbour → Nobu — Saturday at 10:00')).toBeTruthy();
  const eligible=screen.getByLabelText('Eligible route') as HTMLSelectElement;
  expect(Array.from(eligible.options).map(option=>option.text)).toContain('Jolly Harbour → Nobu — Tuesday at 11:00');
  await user.selectOptions(eligible,'tuesday');
  await user.click(screen.getByRole('button',{name:'+ Add route'}));
  expect(screen.getByText('Jolly Harbour → Nobu — Saturday at 10:00')).toBeTruthy();
  expect(screen.getByText('Jolly Harbour → Nobu — Tuesday at 11:00')).toBeTruthy();
 });

 it('submits discount and threshold values as one aggregate payload',async()=>{
  const onSave=setup();const user=userEvent.setup();
  await user.click(screen.getByRole('button',{name:'Save changes'}));
  expect(onSave).toHaveBeenCalledOnce();
  expect(onSave.mock.calls[0][0]).toMatchObject({vehicle_id:'v1',preferred_captain_id:'c1',route_offers:[{service_id:'saturday',route_id:'r1',preferred_captain_id:'c2',post_min_discount_bps:1500,below_minimum_operation_mode:'custom_threshold',min_value_threshold_ratio:.8}]});
 });
});
