// @vitest-environment jsdom
import React from 'react';
import {render,screen,cleanup} from '@testing-library/react';
import {afterEach,it,expect,vi} from 'vitest';
import {CustomerFeedback} from './customer-feedback';
vi.mock('@/lib/data',()=>({loadCustomerFeedbackBooking:vi.fn(async()=>({data:[{booking_id:'b',route_name:'Jolly Harbour to Catherine’s Cafe',departure_status:'completed'}],error:null})),loadCustomerFeedback:vi.fn(async()=>({data:[],error:null})),customerSubmitJourneyFeedback:vi.fn()}));
afterEach(cleanup);
it('opens directly on the questions without dashboard cards',async()=>{
 render(<CustomerFeedback bookingId="b"/>);
 expect(await screen.findByText('How likely are you to recommend Pace Shuttles to a friend?')).toBeTruthy();
 expect(screen.queryByText('Seats booked')).toBeNull();
 expect(screen.queryByText('My Bookings')).toBeNull();
});
