// @vitest-environment jsdom
import React,{useState} from 'react';
import {readFileSync} from 'node:fs';
import {cleanup,render,screen,waitFor,within} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,describe,expect,it,vi} from 'vitest';
import {CaptainToday,type CaptainTodayActions,type CaptainTodayDutyRow,type CaptainTodayActionResult,type CaptainTodayReloadResult} from './captain-today';

const now=new Date('2030-06-10T09:00:00Z');
const activeDuty={
 duty_id:'allocation-active',confirmed_allocation_id:'allocation-active',country_timezone:'UTC',
 first_scheduled_departure_ts:'2030-06-10T08:30:00Z',leg_1_departure_id:'leg-active',leg_1_name:'Harbour to Island',leg_1_scheduled_arrival_ts:'2030-06-10T09:15:00Z',
 leg_1_scheduled_departure_ts:'2030-06-10T08:30:00Z',leg_1_started_at:'2030-06-10T08:35:00Z',
 pickup_name:'North Pier',vehicle_name:'Pace One',operator_name:'Pace Shuttles',duty_state:'leg_1_in_progress',
};
const laterDuty={
 duty_id:'allocation-later',confirmed_allocation_id:'allocation-later',country_timezone:'UTC',
 first_scheduled_departure_ts:'2030-06-10T13:00:00Z',leg_1_departure_id:'leg-later',leg_1_name:'Island to Harbour',leg_1_scheduled_arrival_ts:'2030-06-10T13:45:00Z',
 leg_1_scheduled_departure_ts:'2030-06-10T13:00:00Z',pickup_name:'Island Dock',vehicle_name:'Pace Two',operator_name:'Pace Shuttles',duty_state:'ready',
};
const party={
 duty_id:'allocation-active',confirmed_allocation_id:'allocation-active',booking_id:'booking-michelle',lead_passenger_name:'Michelle Fairbrother',
 adult_count:3,child_count:2,infant_count:1,payment_status:'paid',special_requirements_present:true,unread_count:2,
 passengers:[
  {first_name:'Michelle',last_name:'Fairbrother',age_group:'adult',notes:'Step-free boarding'},
  {first_name:'Alex',last_name:'Fairbrother',age_group:'adult'},
  {first_name:'Sam',last_name:'Fairbrother',age_group:'adult'},
  {first_name:'Ari',last_name:'Fairbrother',age_group:'child'},
  {first_name:'Jo',last_name:'Fairbrother',age_group:'child'},
  {first_name:'Noa',last_name:'Fairbrother',age_group:'infant'},
 ],
};

const pairedReadyDuty:CaptainTodayDutyRow={...laterDuty,duty_id:'allocation-paired',confirmed_allocation_id:'allocation-paired',leg_1_departure_id:'leg-1',leg_1_name:'Harbour to Island',leg_2_departure_id:'leg-2',leg_2_name:'Island to Harbour',leg_2_scheduled_departure_ts:'2030-06-10T14:00:00Z',leg_2_scheduled_arrival_ts:'2030-06-10T14:45:00Z'};
const success={data:'2030-06-10T09:05:00Z',error:null};
const legActions=(overrides:Partial<CaptainTodayActions>={}):CaptainTodayActions=>({
 startLeg:vi.fn(async(departureId:string)=>({data:departureId==='leg-2'?'2030-06-10T14:05:00Z':'2030-06-10T09:05:00Z',error:null})),
 endLeg:vi.fn(async(departureId:string)=>({data:departureId==='leg-2'?'2030-06-10T14:40:00Z':'2030-06-10T09:35:00Z',error:null})),
 ...overrides
});
const reloadResult=(duties:readonly CaptainTodayDutyRow[],manifest:readonly any[]=[]):CaptainTodayReloadResult=>({duties,manifest});
const emptyReload=async()=>reloadResult([]);

function ActionHarness({actions=legActions()}:{actions?:CaptainTodayActions}){
 const [duty,setDuty]=useState<CaptainTodayDutyRow>(pairedReadyDuty);
 const reload=async()=>{
  let next:CaptainTodayDutyRow|undefined;
  setDuty(current=>{
   next=!current.leg_1_started_at?{...current,leg_1_started_at:'2030-06-10T09:05:00Z',duty_state:'leg_1_in_progress'}:!current.leg_1_ended_at?{...current,leg_1_ended_at:'2030-06-10T09:35:00Z',leg_1_completion_state:'normal',leg_1_notes:'',leg_1_incident_summary:null,duty_state:'awaiting_leg_2'}:!current.leg_2_started_at?{...current,leg_2_started_at:'2030-06-10T14:05:00Z',duty_state:'leg_2_in_progress'}:{...current,leg_2_ended_at:'2030-06-10T14:40:00Z',leg_2_completion_state:'normal',leg_2_notes:'',leg_2_incident_summary:null,duty_state:'completed'};
   return next;
  });
  return reloadResult([next!]);
 };
 return <CaptainToday duties={[duty]} manifest={[]} now={now} onSelectedDutyIdChange={vi.fn()} actions={actions} onReload={reload}/>;
}

afterEach(()=>cleanup());

describe('CaptainToday',()=>{
 it('shows the active duty in full and keeps later duties compact without planning copy',()=>{
  render(<CaptainToday duties={[laterDuty,activeDuty]} manifest={[party]} now={now} onSelectedDutyIdChange={vi.fn()} onReload={emptyReload}/>);

  expect(screen.getByRole('heading',{name:'Harbour to Island'})).toBeTruthy();
  expect(screen.getByText(/08:30.*North Pier/,{selector:'.captain-pickup'})).toBeTruthy();
  expect(screen.queryByText(/08:30.*Harbour to Island/,{selector:'.captain-pickup'})).toBeNull();
  expect(screen.getByText(/Pace One.*Pace Shuttles/,{selector:'.captain-vehicle'})).toBeTruthy();
  expect(screen.getByRole('button',{name:/Island to Harbour/i})).toBeTruthy();
  expect(screen.queryByText(/assigned journeys|ready to start|planning/i)).toBeNull();
 });

 it('keeps a non-interactive Leg 2 tab and Not configured section for one-way duties',()=>{
  render(<CaptainToday duties={[activeDuty]} manifest={[party]} now={now} onSelectedDutyIdChange={vi.fn()} onReload={emptyReload}/>);

  const leg2=screen.getByText('Leg 2',{selector:'.captain-today-tabs [aria-disabled="true"]'});
  expect(leg2.tagName).not.toBe('A');
  expect(leg2.getAttribute('href')).toBeNull();
  expect(screen.queryByRole('link',{name:'Leg 2'})).toBeNull();
  expect(screen.getByRole('heading',{name:'Leg 2'})).toBeTruthy();
  expect(screen.getByText('Leg 2 is not configured for this one-way duty.')).toBeTruthy();
 });

 it('derives each configured leg badge from its own recorded lifecycle evidence',()=>{
  const duty:CaptainTodayDutyRow={
   ...pairedReadyDuty,
   leg_1_started_at:'2030-06-10T09:05:00Z',
   leg_1_ended_at:'2030-06-10T09:35:00Z',
   leg_1_completion_state:'incident',
   leg_2_started_at:'2030-06-10T14:05:00Z',
   duty_state:'incident'
  };
  const view=render(<CaptainToday duties={[duty]} manifest={[]} now={now} onSelectedDutyIdChange={vi.fn()} onReload={emptyReload}/>);

  expect(within(screen.getByRole('heading',{name:'Leg 1'}).parentElement!).getByText('Incident')).toBeTruthy();
  expect(within(screen.getByRole('heading',{name:'Leg 2'}).parentElement!).getByText('Under way')).toBeTruthy();
  view.rerender(<CaptainToday duties={[pairedReadyDuty]} manifest={[]} now={now} onSelectedDutyIdChange={vi.fn()} onReload={emptyReload}/>);
  expect(within(screen.getByRole('heading',{name:'Leg 1'}).parentElement!).getByText('Scheduled')).toBeTruthy();
  view.rerender(<CaptainToday duties={[{...pairedReadyDuty,leg_1_started_at:'2030-06-10T09:05:00Z',leg_1_ended_at:'2030-06-10T09:35:00Z',leg_1_completion_state:'normal'}]} manifest={[]} now={now} onSelectedDutyIdChange={vi.fn()} onReload={emptyReload}/>);
  expect(within(screen.getByRole('heading',{name:'Leg 1'}).parentElement!).getByText('Completed')).toBeTruthy();
 });

 it('expands a grouped party without exposing contact details',async()=>{
  const messageParty=vi.fn();
  render(<CaptainToday duties={[activeDuty]} manifest={[party]} now={now} onSelectedDutyIdChange={vi.fn()} onMessageParty={messageParty} onReload={emptyReload}/>);
  const user=userEvent.setup();

  const disclosure=screen.getByRole('button',{name:/Michelle Fairbrother.*3 adults, 2 children, 1 infant/i});
  expect(disclosure.getAttribute('aria-expanded')).toBe('false');
  expect(screen.getByText('PAID')).toBeTruthy();
  await user.click(disclosure);

  expect(disclosure.getAttribute('aria-expanded')).toBe('true');
  expect(within(screen.getByText('Michelle Fairbrother',{selector:'li b'}).closest('li')!).getByText('adult')).toBeTruthy();
  expect(within(screen.getByText('Ari Fairbrother',{selector:'li b'}).closest('li')!).getByText('child')).toBeTruthy();
  expect(within(screen.getByText('Noa Fairbrother',{selector:'li b'}).closest('li')!).getByText('infant')).toBeTruthy();
  expect(screen.getByText('Step-free boarding')).toBeTruthy();
  await user.click(screen.getByRole('button',{name:'Message a party'}));
  expect(messageParty).toHaveBeenCalledWith(party);
 expect(screen.queryByText(/@|\+44|email|phone/i)).toBeNull();
 });

 it('keeps a completed same-day duty selectable',async()=>{
  const completed={...laterDuty,duty_id:'allocation-completed',confirmed_allocation_id:'allocation-completed',leg_1_started_at:'2030-06-10T12:30:00Z',leg_1_ended_at:'2030-06-10T12:50:00Z',leg_1_completion_state:'normal',duty_state:'completed'};
  const change=vi.fn();
  render(<CaptainToday duties={[activeDuty,completed]} manifest={[]} now={now} selectedDutyId="allocation-completed" onSelectedDutyIdChange={change} onReload={emptyReload}/>);

  expect(screen.getByRole('heading',{name:'Island to Harbour'})).toBeTruthy();
  expect(screen.getAllByText('Completed').length).toBeGreaterThan(0);
  await userEvent.setup().click(screen.getByRole('button',{name:/Harbour to Island/i}));
  expect(change).toHaveBeenCalledWith('allocation-active');
 });

 it('enables only the next leg action and reloads authoritative timing evidence',async()=>{
  const actions=legActions();
  const confirm=vi.spyOn(window,'confirm').mockReturnValue(true);
  render(<ActionHarness actions={actions}/>);
  const user=userEvent.setup();

  expect((screen.getByRole('button',{name:'Start Leg 1'}) as HTMLButtonElement).disabled).toBe(false);
  expect((screen.getByRole('button',{name:'End Leg 1'}) as HTMLButtonElement).disabled).toBe(true);
  expect((screen.getByRole('button',{name:'Start Leg 2'}) as HTMLButtonElement).disabled).toBe(true);
  expect((screen.getByRole('button',{name:'End Leg 2'}) as HTMLButtonElement).disabled).toBe(true);
  await user.click(screen.getByRole('button',{name:'Start Leg 1'}));
  expect(confirm).toHaveBeenCalledWith('Start Leg 1: Harbour to Island? This records the actual departure time.');
  expect(actions.startLeg).toHaveBeenCalledWith('leg-1');
  expect(screen.getByText(/Actual departure 09:05/)).toBeTruthy();
  expect((screen.getByRole('button',{name:'End Leg 1'}) as HTMLButtonElement).disabled).toBe(false);

  await user.click(screen.getByRole('button',{name:'End Leg 1'}));
  await user.click(screen.getByRole('button',{name:'Record end time'}));
  expect(actions.endLeg).toHaveBeenCalledWith('leg-1','normal','','');
  expect((screen.getByRole('button',{name:'Start Leg 2'}) as HTMLButtonElement).disabled).toBe(false);
  await user.click(screen.getByRole('button',{name:'Start Leg 2'}));
  await user.click(screen.getByRole('button',{name:'End Leg 2'}));
  await user.click(screen.getByRole('button',{name:'Record end time'}));
  expect(actions.endLeg).toHaveBeenLastCalledWith('leg-2','normal','','');
  expect(screen.getByText('Completed',{selector:'.captain-duty-state'})).toBeTruthy();
  confirm.mockRestore();
 });

 it('guards double taps and keeps only one timing request in flight',async()=>{
  let resolve:(value:CaptainTodayActionResult)=>void=()=>{};
  const actions=legActions({startLeg:vi.fn((_:string):Promise<CaptainTodayActionResult>=>new Promise(done=>{resolve=done;}))});
  vi.spyOn(window,'confirm').mockReturnValue(true);
  render(<CaptainToday duties={[pairedReadyDuty]} manifest={[]} now={now} onSelectedDutyIdChange={vi.fn()} actions={actions} onReload={emptyReload}/>);
  const button=screen.getByRole('button',{name:'Start Leg 1'}),user=userEvent.setup();
  await user.dblClick(button);
  expect(actions.startLeg).toHaveBeenCalledTimes(1);
  resolve(success);
 });

 it('requires incident detail, preserves failed end drafts, and closes after a successful reload',async()=>{
  const actions=legActions({endLeg:vi.fn().mockResolvedValueOnce({data:null,error:new Error('Connection lost')}).mockResolvedValueOnce({data:'2030-06-10T09:35:00Z',error:null})});
  const started={...pairedReadyDuty,leg_1_started_at:'2030-06-10T09:05:00Z',duty_state:'leg_1_in_progress'};
  const reload=vi.fn(async()=>reloadResult([{...started,leg_1_ended_at:'2030-06-10T09:35:00Z',leg_1_completion_state:'incident',leg_1_notes:'Arrived safely',leg_1_incident_summary:'Engine alarm cleared',duty_state:'incident'}]));
  render(<CaptainToday duties={[started]} manifest={[]} now={now} onSelectedDutyIdChange={vi.fn()} actions={actions} onReload={reload}/>);
  const user=userEvent.setup();
  await user.click(screen.getByRole('button',{name:'End Leg 1'}));
  expect((screen.getByRole('radio',{name:'Normal completion'}) as HTMLInputElement).checked).toBe(true);
  await user.click(screen.getByRole('radio',{name:'Incident'}));
  await user.click(screen.getByRole('button',{name:'Record end time'}));
  expect(screen.getByText('An incident summary is required.')).toBeTruthy();
  await user.type(screen.getByLabelText('Incident summary'),'Engine alarm cleared');
  await user.type(screen.getByLabelText('Journey notes (optional)'),'Arrived safely');
  await user.click(screen.getByRole('button',{name:'Record end time'}));
  expect(screen.getByText('Connection lost')).toBeTruthy();
  expect((screen.getByLabelText('Incident summary') as HTMLTextAreaElement).value).toBe('Engine alarm cleared');
  expect((screen.getByLabelText('Journey notes (optional)') as HTMLTextAreaElement).value).toBe('Arrived safely');
  await user.click(screen.getByRole('button',{name:'Record end time'}));
  expect(actions.endLeg).toHaveBeenLastCalledWith('leg-1','incident','Arrived safely','Engine alarm cleared');
  expect(reload).toHaveBeenCalledTimes(1);
  expect(screen.queryByRole('heading',{name:'Record Leg 1 end'})).toBeNull();
 });

 it('scopes a completion draft to its duty when the selected duty becomes stale',async()=>{
  const first={...pairedReadyDuty,leg_1_started_at:'2030-06-10T09:05:00Z',duty_state:'leg_1_in_progress'};
  const second={...pairedReadyDuty,duty_id:'allocation-second',confirmed_allocation_id:'allocation-second',leg_1_departure_id:'second-leg-1',leg_2_departure_id:'second-leg-2'};
  const props={duties:[first,second],manifest:[],now,onSelectedDutyIdChange:vi.fn(),actions:legActions(),onReload:emptyReload};
  const view=render(<CaptainToday {...props} selectedDutyId="allocation-paired"/>);
  const user=userEvent.setup();
  await user.click(screen.getByRole('button',{name:'End Leg 1'}));
  await user.click(screen.getByRole('radio',{name:'Incident'}));
  await user.type(screen.getByLabelText('Incident summary'),'Scoped to first duty');
  view.rerender(<CaptainToday {...props} selectedDutyId="allocation-second"/>);
  expect(screen.queryByRole('heading',{name:'Record Leg 1 end'})).toBeNull();
  view.rerender(<CaptainToday {...props} selectedDutyId="allocation-paired"/>);
  await user.click(screen.getByRole('button',{name:'End Leg 1'}));
  expect((screen.getByLabelText('Incident summary') as HTMLTextAreaElement).value).toBe('Scoped to first duty');
 });

 it('keeps a successful start locked until verified timing evidence refreshes, then retries only the refresh',async()=>{
  const started={...pairedReadyDuty,leg_1_started_at:'2030-06-10T09:05:00Z',duty_state:'leg_1_in_progress'};
  const actions=legActions();
  const reload=vi.fn().mockRejectedValueOnce(new Error('Refresh unavailable')).mockResolvedValueOnce(reloadResult([started]));
  vi.spyOn(window,'confirm').mockReturnValue(true);
  render(<CaptainToday duties={[pairedReadyDuty]} manifest={[]} now={now} onSelectedDutyIdChange={vi.fn()} actions={actions} onReload={reload}/>);
  const user=userEvent.setup();
  await user.click(screen.getByRole('button',{name:'Start Leg 1'}));
  expect(actions.startLeg).toHaveBeenCalledTimes(1);
  expect(screen.getByText(/Refresh unavailable/)).toBeTruthy();
  expect((screen.getByRole('button',{name:'Start Leg 1'}) as HTMLButtonElement).disabled).toBe(true);
  await user.click(screen.getByRole('button',{name:'Refresh timing evidence'}));
  expect(actions.startLeg).toHaveBeenCalledTimes(1);
  expect(screen.getByText(/Actual departure 09:05/)).toBeTruthy();
  expect((screen.getByRole('button',{name:'End Leg 1'}) as HTMLButtonElement).disabled).toBe(false);
 });

 it('accepts the same submitted start evidence when another device has legally ended Leg 1',async()=>{
  const actions=legActions({startLeg:vi.fn(async()=>({data:'2030-06-10T09:05:00Z',error:null}))});
  const advanced={
   ...pairedReadyDuty,
   leg_1_started_at:'2030-06-10T09:05:00Z',
   leg_1_ended_at:'2030-06-10T09:35:00Z',
   leg_1_completion_state:'normal',
   leg_1_notes:'Ended from the bridge tablet',
   leg_1_incident_summary:null,
   duty_state:'awaiting_leg_2'
  };
  const reload=vi.fn(async()=>reloadResult([advanced]));
  vi.spyOn(window,'confirm').mockReturnValue(true);
  render(<CaptainToday duties={[pairedReadyDuty]} manifest={[]} now={now} onSelectedDutyIdChange={vi.fn()} actions={actions} onReload={reload}/>);

  await userEvent.setup().click(screen.getByRole('button',{name:'Start Leg 1'}));

  expect(screen.getByText(/Actual departure 09:05/)).toBeTruthy();
  expect(screen.getByText(/Actual arrival 09:35/)).toBeTruthy();
  expect(screen.queryByRole('button',{name:'Refresh timing evidence'})).toBeNull();
  expect((screen.getByRole('button',{name:'Start Leg 2'}) as HTMLButtonElement).disabled).toBe(false);
 });

 it('keeps refresh pending until the submitted timestamp is present, then accepts a later legal state',async()=>{
  const actions=legActions({startLeg:vi.fn(async()=>({data:'2030-06-10T09:05:00Z',error:null}))});
  const wrongTimestamp={...pairedReadyDuty,leg_1_started_at:'2030-06-10T09:06:00Z',duty_state:'leg_1_in_progress'};
  const recovered={
   ...pairedReadyDuty,
   leg_1_started_at:'2030-06-10T09:05:00Z',
   leg_1_ended_at:'2030-06-10T09:35:00Z',
   leg_1_completion_state:'normal',
   leg_1_notes:null,
   leg_1_incident_summary:null,
   duty_state:'awaiting_leg_2'
  };
  const reload=vi.fn().mockResolvedValueOnce(reloadResult([wrongTimestamp])).mockResolvedValueOnce(reloadResult([recovered]));
  vi.spyOn(window,'confirm').mockReturnValue(true);
  render(<CaptainToday duties={[pairedReadyDuty]} manifest={[]} now={now} onSelectedDutyIdChange={vi.fn()} actions={actions} onReload={reload}/>);
  const user=userEvent.setup();

  await user.click(screen.getByRole('button',{name:'Start Leg 1'}));
  expect(screen.getByRole('button',{name:'Refresh timing evidence'})).toBeTruthy();
  expect(screen.queryByText(/Actual departure 09:06/)).toBeNull();
  await user.click(screen.getByRole('button',{name:'Refresh timing evidence'}));

  expect(actions.startLeg).toHaveBeenCalledTimes(1);
  expect(screen.queryByRole('button',{name:'Refresh timing evidence'})).toBeNull();
  expect((screen.getByRole('button',{name:'Start Leg 2'}) as HTMLButtonElement).disabled).toBe(false);
 });

 it('accepts the submitted Leg 1 end when another device has legally started Leg 2',async()=>{
  const started={...pairedReadyDuty,leg_1_started_at:'2030-06-10T09:05:00Z',duty_state:'leg_1_in_progress'};
  const advanced={
   ...started,
   leg_1_ended_at:'2030-06-10T09:35:00Z',
   leg_1_completion_state:'normal',
   leg_1_notes:'All clear',
   leg_1_incident_summary:null,
   leg_2_started_at:'2030-06-10T14:05:00Z',
   duty_state:'leg_2_in_progress'
  };
  const actions=legActions({endLeg:vi.fn(async()=>({data:'2030-06-10T09:35:00Z',error:null}))});
  render(<CaptainToday duties={[started]} manifest={[]} now={now} onSelectedDutyIdChange={vi.fn()} actions={actions} onReload={async()=>reloadResult([advanced])}/>);
  const user=userEvent.setup();

  await user.click(screen.getByRole('button',{name:'End Leg 1'}));
  await user.type(screen.getByLabelText('Journey notes (optional)'),'All clear');
  await user.click(screen.getByRole('button',{name:'Record end time'}));

  expect(screen.queryByRole('button',{name:'Refresh timing evidence'})).toBeNull();
  expect(screen.getByText(/Actual arrival 09:35/)).toBeTruthy();
  expect(screen.getByText(/Actual departure 14:05/)).toBeTruthy();
  expect((screen.getByRole('button',{name:'End Leg 2'}) as HTMLButtonElement).disabled).toBe(false);
 });

 it('accepts an authoritative missing row after the final paired Leg 2 End and shows remaining duties',async()=>{
  const leg2Started={
   ...pairedReadyDuty,
   leg_1_started_at:'2030-06-10T09:05:00Z',
   leg_1_ended_at:'2030-06-10T09:35:00Z',
   leg_1_completion_state:'normal',
   leg_1_notes:'',
   leg_1_incident_summary:null,
   leg_2_started_at:'2030-06-10T14:05:00Z',
   duty_state:'leg_2_in_progress'
  };
  const sibling={...pairedReadyDuty,duty_id:'allocation-sibling',confirmed_allocation_id:'allocation-sibling',leg_1_name:'Sibling outbound',leg_2_name:'Sibling return'};
  const actions=legActions({endLeg:vi.fn(async()=>({data:'2030-06-10T14:40:00Z',error:null}))});
  const onSelectedDutyIdChange=vi.fn();
  render(<CaptainToday duties={[leg2Started,sibling]} manifest={[]} now={now} selectedDutyId="allocation-paired" onSelectedDutyIdChange={onSelectedDutyIdChange} actions={actions} onReload={async()=>reloadResult([sibling])}/>);
  const user=userEvent.setup();

  await user.click(screen.getByRole('button',{name:'End Leg 2'}));
  await user.type(screen.getByLabelText('Journey notes (optional)'),'Final return complete');
  await user.click(screen.getByRole('button',{name:'Record end time'}));

  expect(screen.queryByRole('button',{name:'Refresh timing evidence'})).toBeNull();
  expect(screen.getByRole('heading',{name:'Sibling outbound'})).toBeTruthy();
  expect(screen.queryByText('Final return complete')).toBeNull();
  expect(onSelectedDutyIdChange).toHaveBeenCalledWith('');
 });

 it('rejects an authoritative missing row after a nonterminal paired end',async()=>{
  const leg1Started={...pairedReadyDuty,leg_1_started_at:'2030-06-10T09:05:00Z',duty_state:'leg_1_in_progress'};
  const actions=legActions({endLeg:vi.fn(async()=>({data:'2030-06-10T09:35:00Z',error:null}))});
  const onSelectedDutyIdChange=vi.fn();
  render(<CaptainToday duties={[leg1Started,laterDuty]} manifest={[]} now={now} selectedDutyId="allocation-paired" onSelectedDutyIdChange={onSelectedDutyIdChange} actions={actions} onReload={async()=>reloadResult([laterDuty])}/>);
  const user=userEvent.setup();

  await user.click(screen.getByRole('button',{name:'End Leg 1'}));
  await user.click(screen.getByRole('button',{name:'Record end time'}));

  expect(screen.getByRole('button',{name:'Refresh timing evidence'})).toBeTruthy();
  expect(screen.getByRole('heading',{name:'Harbour to Island'})).toBeTruthy();
  expect(onSelectedDutyIdChange).not.toHaveBeenCalled();
 });

 it('clears incident detail when Normal is selected and submits canonical empty summary',async()=>{
  const started={...pairedReadyDuty,leg_1_started_at:'2030-06-10T09:05:00Z',duty_state:'leg_1_in_progress'};
  const ended={...started,leg_1_ended_at:'2030-06-10T09:35:00Z',leg_1_completion_state:'normal',leg_1_notes:'All clear',leg_1_incident_summary:null,duty_state:'awaiting_leg_2'};
  const actions=legActions({endLeg:vi.fn(async()=>({data:'2030-06-10T09:35:00Z',error:null}))});
  render(<CaptainToday duties={[started]} manifest={[]} now={now} onSelectedDutyIdChange={vi.fn()} actions={actions} onReload={async()=>reloadResult([ended])}/>);
  const user=userEvent.setup();

  await user.click(screen.getByRole('button',{name:'End Leg 1'}));
  await user.click(screen.getByRole('radio',{name:'Incident'}));
  await user.type(screen.getByLabelText('Incident summary'),'Engine alarm');
  await user.type(screen.getByLabelText('Journey notes (optional)'),'All clear');
  await user.click(screen.getByRole('radio',{name:'Normal completion'}));
  await user.click(screen.getByRole('radio',{name:'Incident'}));
  expect((screen.getByLabelText('Incident summary') as HTMLTextAreaElement).value).toBe('');
  await user.click(screen.getByRole('radio',{name:'Normal completion'}));
  await user.click(screen.getByRole('button',{name:'Record end time'}));

  expect(actions.endLeg).toHaveBeenCalledWith('leg-1','normal','All clear','');
 });

 it.each([
  ['missing acted evidence',{}],
  ['different timestamp',{leg_1_ended_at:'2030-06-10T09:36:00Z',leg_1_completion_state:'normal',leg_1_notes:'All clear',leg_1_incident_summary:null,duty_state:'awaiting_leg_2'}],
  ['different payload',{leg_1_ended_at:'2030-06-10T09:35:00Z',leg_1_completion_state:'normal',leg_1_notes:'Different notes',leg_1_incident_summary:null,duty_state:'awaiting_leg_2'}],
  ['incident-conflicting state',{leg_1_ended_at:'2030-06-10T09:35:00Z',leg_1_completion_state:'incident',leg_1_notes:'All clear',leg_1_incident_summary:'Unexpected incident',duty_state:'incident'}],
  ['different duty',{duty_id:'duty-other',leg_1_ended_at:'2030-06-10T09:35:00Z',leg_1_completion_state:'normal',leg_1_notes:'All clear',leg_1_incident_summary:null,duty_state:'awaiting_leg_2'}],
  ['different allocation',{confirmed_allocation_id:'allocation-other',leg_1_ended_at:'2030-06-10T09:35:00Z',leg_1_completion_state:'normal',leg_1_notes:'All clear',leg_1_incident_summary:null,duty_state:'awaiting_leg_2'}],
 ] as const)('rejects refreshed end evidence with %s',async(_label,changes)=>{
  const started={...pairedReadyDuty,leg_1_started_at:'2030-06-10T09:05:00Z',duty_state:'leg_1_in_progress'};
  const actions=legActions({endLeg:vi.fn(async()=>({data:'2030-06-10T09:35:00Z',error:null}))});
  render(<CaptainToday duties={[started]} manifest={[]} now={now} onSelectedDutyIdChange={vi.fn()} actions={actions} onReload={async()=>reloadResult([{...started,...changes}])}/>);
  const user=userEvent.setup();

  await user.click(screen.getByRole('button',{name:'End Leg 1'}));
  await user.type(screen.getByLabelText('Journey notes (optional)'),'All clear');
  await user.click(screen.getByRole('button',{name:'Record end time'}));

  expect(screen.getByRole('button',{name:'Refresh timing evidence'})).toBeTruthy();
  expect(screen.queryByText(/Actual arrival/)).toBeNull();
  expect(actions.endLeg).toHaveBeenCalledTimes(1);
 });

 it('aborts and ignores a late authoritative reload when selection changes',async()=>{
  let resolve:(value:CaptainTodayReloadResult)=>void=()=>{};
  let request:{dutyId:string;requestId:string;signal:AbortSignal}|undefined;
  const first={...pairedReadyDuty,leg_1_name:'First route'};
  const second={...pairedReadyDuty,duty_id:'allocation-second',confirmed_allocation_id:'allocation-second',leg_1_departure_id:'second-leg-1',leg_2_departure_id:'second-leg-2',leg_1_name:'Second route'};
  const onReload=vi.fn((value:{dutyId:string;requestId:string;signal:AbortSignal})=>{request=value;return new Promise<CaptainTodayReloadResult>(done=>{resolve=done;});});
  const actions=legActions();
  vi.spyOn(window,'confirm').mockReturnValue(true);
  const view=render(<CaptainToday duties={[first,second]} manifest={[]} now={now} selectedDutyId="allocation-paired" onSelectedDutyIdChange={vi.fn()} actions={actions} onReload={onReload}/>);
  await userEvent.setup().click(screen.getByRole('button',{name:'Start Leg 1'}));
  expect(request?.dutyId).toBe('allocation-paired');
  expect(request?.requestId).toBeTruthy();
  view.rerender(<CaptainToday duties={[first,second]} manifest={[]} now={now} selectedDutyId="allocation-second" onSelectedDutyIdChange={vi.fn()} actions={actions} onReload={onReload}/>);
  expect(request?.signal.aborted).toBe(true);
  resolve(reloadResult([{...first,leg_1_started_at:'2030-06-10T09:05:00Z',duty_state:'leg_1_in_progress'}]));
  expect(await screen.findByRole('heading',{name:'Second route'})).toBeTruthy();
  expect(screen.queryByText(/Actual departure 09:05/)).toBeNull();
 });

 it('reconciles an open end panel when authoritative rows make that end action stale',async()=>{
  const started={...pairedReadyDuty,leg_1_started_at:'2030-06-10T09:05:00Z',duty_state:'leg_1_in_progress'};
  const completed={...started,leg_1_ended_at:'2030-06-10T09:35:00Z',leg_1_completion_state:'incident',duty_state:'incident'};
  const view=render(<CaptainToday duties={[started]} manifest={[]} now={now} onSelectedDutyIdChange={vi.fn()} onReload={emptyReload}/>);
  await userEvent.setup().click(screen.getByRole('button',{name:'End Leg 1'}));
  expect(screen.getByRole('button',{name:'Record end time'})).toBeTruthy();
  view.rerender(<CaptainToday duties={[completed]} manifest={[]} now={now} onSelectedDutyIdChange={vi.fn()} onReload={emptyReload}/>);
  expect(screen.queryByRole('button',{name:'Record end time'})).toBeNull();
 });

 it('invalidates a pending start when selection changes so the new duty can act',async()=>{
  let resolve:(value:CaptainTodayActionResult)=>void=()=>{};
  const first={...pairedReadyDuty,leg_1_name:'First route'};
  const second={...pairedReadyDuty,duty_id:'allocation-second',confirmed_allocation_id:'allocation-second',leg_1_departure_id:'second-leg-1',leg_2_departure_id:'second-leg-2',leg_1_name:'Second route'};
  const onReload=vi.fn(emptyReload);
  const actions=legActions({startLeg:vi.fn((departureId:string):Promise<CaptainTodayActionResult>=>departureId==='leg-1'?new Promise(done=>{resolve=done;}):Promise.resolve(success))});
  vi.spyOn(window,'confirm').mockReturnValue(true);
  const view=render(<CaptainToday duties={[first,second]} manifest={[]} now={now} selectedDutyId="allocation-paired" onSelectedDutyIdChange={vi.fn()} actions={actions} onReload={onReload}/>);
  const user=userEvent.setup();
  await user.click(screen.getByRole('button',{name:'Start Leg 1'}));
  view.rerender(<CaptainToday duties={[first,second]} manifest={[]} now={now} selectedDutyId="allocation-second" onSelectedDutyIdChange={vi.fn()} actions={actions} onReload={onReload}/>);
  await waitFor(()=>expect((screen.getByRole('button',{name:'Start Leg 1'}) as HTMLButtonElement).disabled).toBe(false));
  resolve(success);
  await Promise.resolve();
  expect(onReload).not.toHaveBeenCalled();
  await user.click(screen.getByRole('button',{name:'Start Leg 1'}));
  expect(actions.startLeg).toHaveBeenNthCalledWith(2,'second-leg-1');
 });

 it('does not refresh or write after unmount while an end RPC rejects',async()=>{
  let reject:(reason:unknown)=>void=()=>{};
  const started={...pairedReadyDuty,leg_1_started_at:'2030-06-10T09:05:00Z',duty_state:'leg_1_in_progress'};
  const actions=legActions({endLeg:vi.fn((_:string,_state:'normal'|'incident',_notes:string,_summary:string):Promise<CaptainTodayActionResult>=>new Promise((_done,fail)=>{reject=fail;}))});
  const reload=vi.fn(emptyReload);
  const consoleError=vi.spyOn(console,'error').mockImplementation(()=>{});
  const view=render(<CaptainToday duties={[started]} manifest={[]} now={now} onSelectedDutyIdChange={vi.fn()} actions={actions} onReload={reload}/>);
  const user=userEvent.setup();
  await user.click(screen.getByRole('button',{name:'End Leg 1'}));
  await user.click(screen.getByRole('button',{name:'Record end time'}));
  view.unmount();
  reject(new Error('Connection lost'));
  await Promise.resolve();
  await Promise.resolve();
  expect(reload).not.toHaveBeenCalled();
  expect(consoleError).not.toHaveBeenCalled();
  consoleError.mockRestore();
 });

 it('uses fixed stacked sticky geometry and keeps anchored section headings visible',()=>{
  const styles=readFileSync('app/globals.css','utf8');
  expect(styles).toMatch(/--app-topbar-height:78px/);
  expect(styles).toMatch(/\.topbar\{[^}]*height:var\(--app-topbar-height\)/);
  expect(styles).toMatch(/@media\(max-width:760px\)\{[^}]*--app-topbar-height:92px/);
  expect(styles).toMatch(/\.captain-workspace-tabs\{[^}]*height:var\(--captain-workspace-tabs-height\)[^}]*top:var\(--app-topbar-height\)/);
  expect(styles).toMatch(/\.captain-workspace \.captain-today-tabs\{[^}]*top:calc\(var\(--app-topbar-height\) \+ var\(--captain-workspace-tabs-height\)\)/);
  expect(styles).toMatch(/\.captain-today :is\(#manifest,#leg-1,#leg-2,#communications\)\{[^}]*scroll-margin-top:calc\(/);
 });
});
