// @vitest-environment jsdom
import React from 'react';
import {cleanup,render,screen,waitFor} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,describe,expect,it,vi} from 'vitest';

const fixtures=vi.hoisted(()=>({
 adminSavePairedJourneyDesign:vi.fn(async()=>({data:[{journey_pair_id:'pair-1'}],error:null})),
 adminLoadPairedJourneyDesign:vi.fn(async()=>({data:[] as any[],error:null})),
 adminLoadRouteReturnMappingOptions:vi.fn(async()=>({data:[] as any[],error:null})),
 adminSaveRouteReturnMapping:vi.fn(async()=>({data:null,error:null}))
}));

vi.mock('@/lib/data',()=>({
 adminSavePairedJourneyDesign:fixtures.adminSavePairedJourneyDesign,
 adminLoadPairedJourneyDesign:fixtures.adminLoadPairedJourneyDesign,
 adminLoadRouteReturnMappingOptions:fixtures.adminLoadRouteReturnMappingOptions,
 adminSaveRouteReturnMapping:fixtures.adminSaveRouteReturnMapping
}));

import {AdminServiceEditor} from './admin-service-editor';

afterEach(()=>{
 cleanup();
 fixtures.adminSavePairedJourneyDesign.mockReset();
 fixtures.adminLoadPairedJourneyDesign.mockReset();
 fixtures.adminLoadRouteReturnMappingOptions.mockReset();
 fixtures.adminSaveRouteReturnMapping.mockReset();
 fixtures.adminSavePairedJourneyDesign.mockResolvedValue({data:[{journey_pair_id:'pair-1'}],error:null});
 fixtures.adminLoadPairedJourneyDesign.mockResolvedValue({data:[],error:null});
 fixtures.adminLoadRouteReturnMappingOptions.mockResolvedValue({data:[],error:null});
 fixtures.adminSaveRouteReturnMapping.mockResolvedValue({data:null,error:null});
});

describe('AdminServiceEditor',()=>{
 it('submits and reports a disabled-return outbound time edit',async()=>{
  const user=userEvent.setup();
  render(<AdminServiceEditor serviceId="service-outbound" outboundLocalTime="09:00"/>);
  await waitFor(()=>expect((screen.getByRole('button',{name:'Save journey design'}) as HTMLButtonElement).disabled).toBe(false));
  await user.clear(screen.getByLabelText('Outbound start time'));
  await user.type(screen.getByLabelText('Outbound start time'),'09:30');
  await user.click(screen.getByRole('button',{name:'Save journey design'}));

  await waitFor(()=>expect(fixtures.adminSavePairedJourneyDesign).toHaveBeenCalledWith({
   serviceId:'service-outbound',outboundLocalTime:'09:30',returnEnabled:false,
   returnLocalTime:null,returnDurationMinutes:null,reverseRouteId:null
  }));
  expect((await screen.findByRole('status')).textContent).toContain('Journey design saved');
 });

 it('shows the return controls and sends the typed paired-design payload',async()=>{
  const user=userEvent.setup();
  render(<AdminServiceEditor serviceId="service-1" outboundLocalTime="10:00:00" returnRoutes={[{id:'return-route-1',route_name:'Harbour return'}]}/>);

  expect(screen.getByLabelText('Return journey')).toBeTruthy();
  const returnTime=screen.getByLabelText('Return start time') as HTMLInputElement;
  const returnDuration=screen.getByLabelText('Return duration (minutes)') as HTMLInputElement;
  expect(returnTime.disabled).toBe(true);
  expect(returnDuration.disabled).toBe(true);

  await user.click(screen.getByLabelText('Return journey'));
  await user.clear(returnTime);
  await user.type(returnTime,'16:00');
  await user.clear(returnDuration);
  await user.type(returnDuration,'30');
  await user.selectOptions(screen.getByLabelText('Return route'),'return-route-1');
  await user.click(screen.getByRole('button',{name:'Save journey design'}));

  await waitFor(()=>expect(fixtures.adminSavePairedJourneyDesign).toHaveBeenCalledWith({
   serviceId:'service-1',outboundLocalTime:'10:00',returnEnabled:true,
   returnLocalTime:'16:00',returnDurationMinutes:30,reverseRouteId:'return-route-1'
  }));
  expect((await screen.findByRole('status')).textContent).toContain('Journey design saved');
 });

 it('keeps entered values visible when protected return removal is refused',async()=>{
  (fixtures.adminSavePairedJourneyDesign as any).mockResolvedValueOnce({data:null,error:{message:'return journey cannot be removed after bookings, allocations or operation evidence exist'}});
  const user=userEvent.setup();
  render(<AdminServiceEditor serviceId="service-2" outboundLocalTime="09:00" returnEnabled returnLocalTime="15:30" returnDurationMinutes={45} returnRouteId="return-route-2" returnRoutes={[{id:'return-route-2',route_name:'Harbour return'}]}/>);

  await user.click(screen.getByLabelText('Return journey'));
  await user.click(screen.getByRole('button',{name:'Save journey design'}));

  expect((await screen.findByRole('alert')).textContent).toContain('return journey cannot be removed');
  expect((screen.getByLabelText('Outbound start time') as HTMLInputElement).value).toBe('09:00');
  expect((screen.getByLabelText('Return start time') as HTMLInputElement).value).toBe('15:30');
 expect((screen.getByLabelText('Return duration (minutes)') as HTMLInputElement).value).toBe('45');
 });

 it('loads an existing paired return design before a subsequent save can remove it',async()=>{
  fixtures.adminLoadPairedJourneyDesign.mockResolvedValueOnce({data:[{outbound_local_time:'10:00:00',return_enabled:true,return_local_time:'16:00:00',return_duration_minutes:30,reverse_route_id:'return-route-3',eligible_return_routes:[{id:'return-route-3',route_name:'Harbour return',is_active:true}]}],error:null});
  render(<AdminServiceEditor serviceId="service-3" outboundLocalTime="09:00" returnRoutes={[{id:'return-route-3',route_name:'Harbour return'}]}/>);

  await waitFor(()=>expect((screen.getByLabelText('Return journey') as HTMLInputElement).checked).toBe(true));
  expect((screen.getByLabelText('Outbound start time') as HTMLInputElement).value).toBe('10:00');
  expect((screen.getByLabelText('Return start time') as HTMLInputElement).value).toBe('16:00');
  expect((screen.getByLabelText('Return duration (minutes)') as HTMLInputElement).value).toBe('30');
  expect((screen.getByLabelText('Return route') as HTMLSelectElement).value).toBe('return-route-3');
 });

 it('resets to the new service defaults when that service has no saved paired design',async()=>{
  fixtures.adminLoadPairedJourneyDesign
   .mockResolvedValueOnce({data:[{outbound_local_time:'10:00:00',return_enabled:true,return_local_time:'16:00:00',return_duration_minutes:30}],error:null})
   .mockResolvedValueOnce({data:[],error:null});
  const {rerender}=render(<AdminServiceEditor serviceId="service-4" outboundLocalTime="09:00"/>);

  await waitFor(()=>expect((screen.getByLabelText('Return journey') as HTMLInputElement).checked).toBe(true));
  rerender(<AdminServiceEditor serviceId="service-5" outboundLocalTime="11:15"/>);

  await waitFor(()=>expect(fixtures.adminLoadPairedJourneyDesign).toHaveBeenLastCalledWith('service-5'));
  expect((screen.getByLabelText('Return journey') as HTMLInputElement).checked).toBe(false);
  expect((screen.getByLabelText('Outbound start time') as HTMLInputElement).value).toBe('11:15');
  expect((screen.getByLabelText('Return start time') as HTMLInputElement).value).toBe('');
  expect((screen.getByLabelText('Return duration (minutes)') as HTMLInputElement).value).toBe('');
 });
});

it('fails closed after a load error until the current service is retried successfully',async()=>{
 let rejectLoad:(error:Error)=>void=()=>{};
 fixtures.adminLoadPairedJourneyDesign.mockImplementationOnce(()=>new Promise((_resolve,reject)=>{rejectLoad=reject}));
 fixtures.adminLoadPairedJourneyDesign.mockResolvedValueOnce({data:[],error:null});
 render(<AdminServiceEditor serviceId="service-6" outboundLocalTime="09:00"/>);
 expect((screen.getByRole('button',{name:'Loading journey design…'}) as HTMLButtonElement).disabled).toBe(true);
 rejectLoad(new Error('Could not load saved journey design'));
 expect((await screen.findByRole('alert')).textContent).toContain('Could not load saved journey design');
 expect((screen.getByRole('button',{name:'Save journey design'}) as HTMLButtonElement).disabled).toBe(true);
 await userEvent.setup().click(screen.getByRole('button',{name:'Retry loading journey design'}));
 await waitFor(()=>expect((screen.getByRole('button',{name:'Save journey design'}) as HTMLButtonElement).disabled).toBe(false));
});

it('does not report an old service save after the service changes',async()=>{
 let resolveSave:(result:any)=>void=()=>{};
 fixtures.adminSavePairedJourneyDesign.mockImplementationOnce(()=>new Promise(resolve=>{resolveSave=resolve}));
 fixtures.adminLoadPairedJourneyDesign.mockResolvedValue({data:[],error:null});
 const user=userEvent.setup();
 const {rerender}=render(<AdminServiceEditor serviceId="service-7" outboundLocalTime="09:00"/>);
 await waitFor(()=>expect((screen.getByRole('button',{name:'Save journey design'}) as HTMLButtonElement).disabled).toBe(false));
 await user.click(screen.getByRole('button',{name:'Save journey design'}));
 rerender(<AdminServiceEditor serviceId="service-8" outboundLocalTime="11:00"/>);
 resolveSave({data:[{journey_pair_id:'pair-7'}],error:null});
 await waitFor(()=>expect((screen.getByRole('button',{name:'Save journey design'}) as HTMLButtonElement).disabled).toBe(false));
 expect(screen.queryByRole('status')).toBeNull();
});

it('reports a rejected save and always clears the save busy state',async()=>{
 fixtures.adminSavePairedJourneyDesign.mockRejectedValueOnce(new Error('Network interrupted'));
 const user=userEvent.setup();
 render(<AdminServiceEditor serviceId="service-9" outboundLocalTime="09:00"/>);
 await waitFor(()=>expect((screen.getByRole('button',{name:'Save journey design'}) as HTMLButtonElement).disabled).toBe(false));
 await user.click(screen.getByRole('button',{name:'Save journey design'}));
 expect((await screen.findByRole('alert')).textContent).toContain('Network interrupted');
 expect((screen.getByRole('button',{name:'Save journey design'}) as HTMLButtonElement).disabled).toBe(false);
});

it('offers only active mapped return routes loaded for this service',async()=>{
 fixtures.adminLoadPairedJourneyDesign.mockResolvedValueOnce({data:[{outbound_local_time:'09:00',return_enabled:false,eligible_return_routes:[{id:'mapped-active',route_name:'Mapped route',is_active:true},{id:'mapped-inactive',route_name:'Inactive route',is_active:false}]}],error:null});
 render(<AdminServiceEditor serviceId="service-10" outboundLocalTime="09:00" returnRoutes={[{id:'unmapped-prop',route_name:'Unmapped prop route',is_active:true}]}/>);
 await waitFor(()=>expect(screen.queryByRole('option',{name:'Mapped route'})).toBeTruthy());
 expect(screen.queryByRole('option',{name:'Inactive route'})).toBeNull();
 expect(screen.queryByRole('option',{name:'Unmapped prop route'})).toBeNull();
});

it('refuses an invalid return route before calling save',async()=>{
 const user=userEvent.setup();
 render(<AdminServiceEditor serviceId="service-11" outboundLocalTime="09:00" returnEnabled returnLocalTime="16:00" returnDurationMinutes={30} returnRouteId="unmapped" returnRoutes={[{id:'mapped',route_name:'Mapped route',is_active:true}]}/>);
 await waitFor(()=>expect((screen.getByRole('button',{name:'Save journey design'}) as HTMLButtonElement).disabled).toBe(false));
 await user.click(screen.getByRole('button',{name:'Save journey design'}));
 expect((await screen.findByRole('alert')).textContent).toContain('Choose an eligible return route');
 expect(fixtures.adminSavePairedJourneyDesign).not.toHaveBeenCalled();
});

it('shows explicit validation errors for missing return fields and invalid minutes',async()=>{
 const user=userEvent.setup();
 render(<AdminServiceEditor serviceId="service-12" outboundLocalTime="09:00" returnEnabled returnRoutes={[{id:'mapped',route_name:'Mapped route',is_active:true}]}/>);
 await waitFor(()=>expect((screen.getByRole('button',{name:'Save journey design'}) as HTMLButtonElement).disabled).toBe(false));
 await user.selectOptions(screen.getByLabelText('Return route'),'mapped');
 await user.click(screen.getByRole('button',{name:'Save journey design'}));
 expect((await screen.findByRole('alert')).textContent).toContain('Return start time is required');
 await user.type(screen.getByLabelText('Return start time'),'16:00');
 await user.click(screen.getByRole('button',{name:'Save journey design'}));
 expect((await screen.findByRole('alert')).textContent).toContain('Return duration is required');
 await user.type(screen.getByLabelText('Return duration (minutes)'),'1.5');
 await user.click(screen.getByRole('button',{name:'Save journey design'}));
 expect((await screen.findByRole('alert')).textContent).toContain('positive whole number');
 expect(fixtures.adminSavePairedJourneyDesign).not.toHaveBeenCalled();
});

it('shows an explicit outbound-time error instead of browser validation',async()=>{
 const user=userEvent.setup();
 render(<AdminServiceEditor serviceId="service-13" outboundLocalTime="09:00"/>);
 await waitFor(()=>expect((screen.getByRole('button',{name:'Save journey design'}) as HTMLButtonElement).disabled).toBe(false));
 await user.clear(screen.getByLabelText('Outbound start time'));
 await user.click(screen.getByRole('button',{name:'Save journey design'}));
 expect((await screen.findByRole('alert')).textContent).toContain('Outbound start time is required');
});

it('bootstraps an empty route mapping and refreshes the return design choices',async()=>{
 const returnRoute={id:'return-route-14',route_name:'Harbour return',is_active:true};
 fixtures.adminLoadRouteReturnMappingOptions
  .mockResolvedValueOnce({data:[{outbound_route_id:'outbound-route-14',outbound_route_name:'Harbour outbound',mapped_return_route_id:null,eligible_return_routes:[returnRoute]}],error:null})
  .mockResolvedValueOnce({data:[{outbound_route_id:'outbound-route-14',outbound_route_name:'Harbour outbound',mapped_return_route_id:returnRoute.id,eligible_return_routes:[returnRoute]}],error:null});
 fixtures.adminLoadPairedJourneyDesign
  .mockResolvedValueOnce({data:[{outbound_local_time:'09:00',return_enabled:false,eligible_return_routes:[]}],error:null})
  .mockResolvedValueOnce({data:[{outbound_local_time:'09:00',return_enabled:false,eligible_return_routes:[returnRoute]}],error:null});
 const user=userEvent.setup();
 render(<AdminServiceEditor serviceId="service-14" outboundLocalTime="09:00"/>);

 await user.selectOptions(await screen.findByLabelText('Mapped return route'),returnRoute.id);
 await user.click(screen.getByRole('button',{name:'Save return route mapping'}));

 await waitFor(()=>expect(fixtures.adminSaveRouteReturnMapping).toHaveBeenCalledWith({
  outboundRouteId:'outbound-route-14',returnRouteId:returnRoute.id
 }));
 expect((await screen.findByRole('status')).textContent).toContain('Return route mapping saved');
 await user.click(screen.getByLabelText('Return journey'));
 expect(Array.from((screen.getByLabelText('Return route') as HTMLSelectElement).options).map(option=>option.text)).toContain('Harbour return');
 expect(fixtures.adminLoadPairedJourneyDesign).toHaveBeenCalledTimes(2);
 expect(fixtures.adminLoadRouteReturnMappingOptions).toHaveBeenCalledTimes(2);
});

it('keeps mapping domain errors and selection visible while guarding duplicate saves',async()=>{
 let resolveSave:(value:{data:null;error:{message:string}})=>void=()=>{};
 fixtures.adminLoadRouteReturnMappingOptions.mockResolvedValueOnce({data:[{
  outbound_route_id:'outbound-route-15',outbound_route_name:'Harbour outbound',mapped_return_route_id:null,
  eligible_return_routes:[{id:'return-route-15',route_name:'Harbour return',is_active:true}]
 }],error:null});
 fixtures.adminSaveRouteReturnMapping.mockImplementationOnce(()=>new Promise(resolve=>{resolveSave=resolve}));
 const user=userEvent.setup();
 render(<AdminServiceEditor serviceId="service-15" outboundLocalTime="09:00"/>);

 const mappingSelect=await screen.findByLabelText('Mapped return route') as HTMLSelectElement;
 await user.selectOptions(mappingSelect,'return-route-15');
 const saveButton=screen.getByRole('button',{name:'Save return route mapping'});
 await user.click(saveButton);
 await user.click(saveButton);
 expect(fixtures.adminSaveRouteReturnMapping).toHaveBeenCalledTimes(1);
 expect((screen.getByRole('button',{name:'Saving route mapping…'}) as HTMLButtonElement).disabled).toBe(true);
 resolveSave({data:null,error:{message:'return route mapping cannot change while a service return design is enabled; disable the design first'}});

 expect((await screen.findByRole('alert')).textContent).toContain('disable the design first');
 expect(mappingSelect.value).toBe('return-route-15');
 expect((screen.getByRole('button',{name:'Save return route mapping'}) as HTMLButtonElement).disabled).toBe(false);
});

it('surfaces the mapping lifecycle rule before an enabled return design can be edited',async()=>{
 fixtures.adminLoadPairedJourneyDesign.mockResolvedValueOnce({data:[{
  outbound_local_time:'09:00',return_enabled:true,return_local_time:'16:00',return_duration_minutes:30,
  reverse_route_id:'return-route-16',eligible_return_routes:[{id:'return-route-16',route_name:'Harbour return'}]
 }],error:null});
 fixtures.adminLoadRouteReturnMappingOptions.mockResolvedValueOnce({data:[{
  outbound_route_id:'outbound-route-16',outbound_route_name:'Harbour outbound',mapped_return_route_id:'return-route-16',
  eligible_return_routes:[{id:'return-route-16',route_name:'Harbour return'}]
 }],error:null});
 render(<AdminServiceEditor serviceId="service-16" outboundLocalTime="09:00"/>);

 expect(await screen.findByText(/disable and save the return journey before changing its route mapping/i)).toBeTruthy();
 expect((screen.getByLabelText('Mapped return route') as HTMLSelectElement).disabled).toBe(true);
 expect((screen.getByRole('button',{name:'Save return route mapping'}) as HTMLButtonElement).disabled).toBe(true);
});
