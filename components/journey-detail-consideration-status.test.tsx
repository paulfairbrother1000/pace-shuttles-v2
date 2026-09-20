// @vitest-environment jsdom
import React from 'react';
import {cleanup,render,screen,waitFor} from '@testing-library/react';
import {afterEach,describe,expect,it,vi} from 'vitest';

const departureId='8e5007e5-8628-4ff7-b738-36fff1e06c82';
const conflictingDepartureId='03115d6d-1344-4bcd-9641-dbd5ccde8abf';

const loaders=vi.hoisted(()=>({
  loadAdminLiveOperationsDetail:vi.fn(async()=>({data:[{
    departure_id:'8e5007e5-8628-4ff7-b738-36fff1e06c82',
    route_name:"St John's → Nikki Beach",
    trip_timezone:'America/Antigua',
    scheduled_departure_ts:'2026-09-21T14:00:00Z',
    scheduled_arrival_ts:'2026-09-21T14:20:00Z',
    t72_ts:'2026-09-18T14:00:00Z',
    t24_ts:'2026-09-20T14:00:00Z',
    departure_status:'scheduled',booking_count:0,booked_seats:0,
    confirmed_vehicle_count:0,active_captain_count:0,
  }],error:null})),
  loadAdminJourneyBookings:vi.fn(async()=>({data:[],error:null})),
  loadAdminJourneyAllocations:vi.fn(async()=>({data:[],error:null})),
  loadAdminRevenueRescues:vi.fn(async()=>({data:[],error:null})),
  loadAdminRevenueRescueContributions:vi.fn(async()=>({data:[],error:null})),
  loadAdminSchedulerRuns:vi.fn(async()=>({data:[],error:null})),
  loadCaptains:vi.fn(async()=>({data:[],error:null})),
  loadAdminVehicleConsiderations:vi.fn(async()=>({data:[
    {
      consideration_id:'conflict',departure_id:'8e5007e5-8628-4ff7-b738-36fff1e06c82',
      operator_name:'Antigua Boats',vehicle_name:'Silver Lady',status:'discarded_t72',
      conflicting_departure_id:'03115d6d-1344-4bcd-9641-dbd5ccde8abf',
      normal_min_seats:6,max_seats:10,min_revenue_cents:30000,
      assigned_seats:0,assigned_revenue_cents:0,normal_base_seat_price_cents:5000,
      quality_score_snapshot:50,withdrawal_deadline_ts:'2026-09-20T14:00:00Z',
      t72_discarded_at:'2026-09-03T16:48:31Z',
    },
    {
      consideration_id:'genuine-t72',departure_id:'8e5007e5-8628-4ff7-b738-36fff1e06c82',
      operator_name:'Barefoot',vehicle_name:'Spare Boat',status:'discarded_t72',
      conflicting_departure_id:null,
      normal_min_seats:4,max_seats:10,min_revenue_cents:50000,
      assigned_seats:0,assigned_revenue_cents:0,normal_base_seat_price_cents:12500,
      quality_score_snapshot:50,withdrawal_deadline_ts:'2026-09-20T14:00:00Z',
      t72_discarded_at:'2026-09-18T14:00:01Z',
    },
    {
      consideration_id:'captain-conflict',departure_id:departureId,
      operator_name:'Barefoot',vehicle_name:'Conflict Boat',status:'discarded_t72',
      captain_resource_reason:'captain_conflict',captain_resource_state:null,
      captain_conflicting_departure_id:'conflicting-departure-id',
      normal_min_seats:4,max_seats:10,min_revenue_cents:50000,
    },
    {
      consideration_id:'no-captain',departure_id:departureId,
      operator_name:'Barefoot',vehicle_name:'No Captain Boat',status:'discarded_t72',
      captain_resource_reason:'no_eligible_captain',
      normal_min_seats:4,max_seats:10,min_revenue_cents:50000,
    },
    {
      consideration_id:'inactive-captain',departure_id:departureId,
      operator_name:'Barefoot',vehicle_name:'Inactive Captain Boat',status:'discarded_t72',
      captain_resource_reason:'captain_inactive',
      normal_min_seats:4,max_seats:10,min_revenue_cents:50000,
    },
    {
      consideration_id:'ineligible-captain',departure_id:departureId,
      operator_name:'Barefoot',vehicle_name:'Ineligible Captain Boat',status:'discarded_t72',
      captain_resource_reason:'captain_ineligible',
      normal_min_seats:4,max_seats:10,min_revenue_cents:50000,
    },
    {
      consideration_id:'held-captain',departure_id:departureId,
      operator_name:'Barefoot',vehicle_name:'Held Boat',status:'under_consideration',
      captain_resource_state:'held_t72',captain_resource_reason:null,
      normal_min_seats:4,max_seats:10,min_revenue_cents:50000,
    },
  ],error:null})),
}));

vi.mock('@/lib/data',async(importOriginal)=>({
  ...(await importOriginal<typeof import('@/lib/data')>()),
  ...loaders,
}));

import {JourneyDetail} from './pages';

afterEach(cleanup);

describe('JourneyDetail vehicle availability reasons',()=>{
  it('links an overlapping allocation as unavailable without relabelling genuine T-72 discards',async()=>{
    render(<JourneyDetail id={departureId}/>);

    const conflictLink=await screen.findByRole('link',{
      name:'UNAVAILABLE — allocated to 03115d6d',
    });
    expect(conflictLink.getAttribute('href')).toBe(`/admin/journeys/${conflictingDepartureId}`);
    await waitFor(()=>expect(screen.getByText('DISCARDED T72')).toBeTruthy());
  });

  it('shows reason-specific captain availability evidence',async()=>{
    render(<JourneyDetail id={departureId}/>);

    expect(await screen.findByText('UNAVAILABLE — captain reserved elsewhere')).toBeTruthy();
    expect(screen.getByRole('link',{name:/view conflicting journey/i}).getAttribute('href'))
      .toBe('/admin/journeys/conflicting-departure-id');
    expect(screen.getByText('No eligible captain')).toBeTruthy();
    expect(screen.getByText('Captain inactive')).toBeTruthy();
    expect(screen.getByText('Captain no longer eligible')).toBeTruthy();
    expect(screen.getByText('Held for this journey')).toBeTruthy();
  });
});
