// @vitest-environment jsdom
import React from 'react';
import {cleanup,render,screen,waitFor} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,beforeEach,describe,expect,it,vi} from 'vitest';

const fixtures=vi.hoisted(()=>({
 adminCreateRouteOffer:vi.fn(async()=>({data:null,error:{message:'test stop'}})),
 operators:[{id:'o1',name:'Island Boats',country_id:'ag',active:true}],
 vehicles:[
  {id:'v1',operator_id:'o1',vehicle_type_id:'boat',name:'Sea Rider',default_min_seats:4,default_max_seats:10,default_min_revenue_cents:140000,default_min_value_threshold_ratio:.8},
  {id:'v2',operator_id:'o1',vehicle_type_id:'taxi',name:'Road Rider',default_min_seats:1,default_max_seats:4,default_min_revenue_cents:20000,default_min_value_threshold_ratio:null}
 ],
 eligibleServices:[
  {operator_id:'o2',route_id:'r9',route_name:'Wrong Operator',service_id:'global-first',days_of_week:[1],departure_time:'07:00:00',timezone:'America/Antigua',vehicle_type_id:'boat',country_id:'ag'},
  {operator_id:'o1',route_id:'r2',route_name:'Airport → Town',service_id:'taxi-service',days_of_week:[1],departure_time:'09:00:00',timezone:'America/Antigua',vehicle_type_id:'taxi',country_id:'ag'},
  {operator_id:'o1',route_id:'r1',route_name:'Jolly Harbour → Nobu',service_id:'saturday',days_of_week:[6],departure_time:'10:00:00',timezone:'America/Antigua',vehicle_type_id:'boat',country_id:'ag'},
  {operator_id:'o1',route_id:'r1',route_name:'Jolly Harbour → Nobu',service_id:'tuesday',days_of_week:[2],departure_time:'11:00:00',timezone:'America/Antigua',vehicle_type_id:'boat',country_id:'ag'}
 ],
 assignments:[{
  offer_id:'of1',operator_id:'o1',vehicle_id:'v1',route_id:'r1',route_name:'Jolly Harbour → Nobu',service_id:'saturday',
  service_days_of_week:[6],service_departure_time:'10:00:00',service_timezone:'America/Antigua',active:true,
  min_seats:4,max_seats:10,min_revenue_cents:140000
 }],
 empty:async()=>({data:[],error:null})
}));

vi.mock('@/lib/data',async importOriginal=>{
 const actual=await importOriginal<typeof import('@/lib/data')>();
 return {...actual,
  loadOperators:async()=>({data:fixtures.operators,error:null}),
  loadVehicles:async()=>({data:fixtures.vehicles,error:null}),
  loadCaptains:fixtures.empty,loadVehicleTypes:fixtures.empty,
  loadAdminServices:async()=>({data:fixtures.eligibleServices,error:null}),
  loadVehicleRouteOffers:async()=>({data:fixtures.assignments,error:null}),
  loadOperatorVehicleEditorRoutes:async()=>({data:fixtures.eligibleServices,error:null}),
  loadOperatorVehicleEditorOffers:async()=>({data:fixtures.assignments,error:null}),
  loadVehicleUnavailability:fixtures.empty,loadOperatorCommissionOverrides:fixtures.empty,
  loadCountryCommissions:fixtures.empty,loadCancellationPolicies:fixtures.empty,
  adminCreateRouteOffer:fixtures.adminCreateRouteOffer
 };
});

import {OperatorDetail} from './pages';

beforeEach(()=>fixtures.adminCreateRouteOffer.mockClear());
afterEach(cleanup);

describe('Site Admin scheduled service assignment',()=>{
 it('requires explicit vehicle and eligible scheduled-service selection before assigning',async()=>{
  const user=userEvent.setup();
  render(<OperatorDetail id="o1"/>);

  const vehicleSelect=await screen.findByLabelText('Assignment vehicle') as HTMLSelectElement;
  const serviceSelect=screen.getByLabelText('Scheduled service') as HTMLSelectElement;
  const assignButton=screen.getByRole('button',{name:'+ Assign Service'});
  expect(vehicleSelect.value).toBe('');
  expect(serviceSelect.disabled).toBe(true);
  expect((assignButton as HTMLButtonElement).disabled).toBe(true);

  await user.selectOptions(vehicleSelect,'v1');
  const serviceLabels=Array.from(serviceSelect.options).map(option=>option.text);
  expect(serviceLabels).toContain('Jolly Harbour → Nobu — Saturday at 10:00');
  expect(serviceLabels).toContain('Jolly Harbour → Nobu — Tuesday at 11:00');
  expect(serviceLabels).not.toContain('Wrong Operator — Monday at 07:00');
  expect(serviceLabels).not.toContain('Airport → Town — Monday at 09:00');

  await user.selectOptions(serviceSelect,'tuesday');
  await user.click(assignButton);
  await waitFor(()=>expect(fixtures.adminCreateRouteOffer).toHaveBeenCalledWith(expect.objectContaining({p_vehicle_id:'v1',p_service_id:'tuesday'})));
 });

 it('shows the scheduled service on existing assignment records',async()=>{
  render(<OperatorDetail id="o1"/>);
  expect(await screen.findByText(/Jolly Harbour → Nobu — Saturday at 10:00/)).toBeTruthy();
 });
});
