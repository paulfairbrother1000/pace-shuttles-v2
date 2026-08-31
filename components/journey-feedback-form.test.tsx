// @vitest-environment jsdom
import React from 'react';
import {cleanup,render,screen} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,describe,expect,it,vi} from 'vitest';
import {JourneyFeedbackForm,useJourneyFeedbackFlow,type FeedbackJourney} from './journey-feedback-form';

const journey:FeedbackJourney={
 booking_id:'booking-1',
 route_name:'St John’s to English Harbour',
 pickup_name:'Heritage Quay',
 destination_name:'English Harbour',
 scheduled_departure_ts:'2030-01-02T13:00:00Z',
};

afterEach(cleanup);

describe('JourneyFeedbackForm',()=>{
 it('renders all approved rating fields and defaults testimonial consent to false',()=>{
  render(<JourneyFeedbackForm journey={journey} onSubmit={vi.fn(async()=>undefined)}/>);

  expect(screen.getByText('How likely are you to recommend Pace Shuttles to a friend?')).toBeTruthy();
  expect((screen.getByLabelText(/testimonial/i) as HTMLInputElement).checked).toBe(false);
  expect(screen.getByText(/pickup location/i)).toBeTruthy();
  expect(screen.getByText(/destination/i)).toBeTruthy();
  expect(screen.getByText(/booking experience/i)).toBeTruthy();
  expect(screen.getByText(/operator and journey/i)).toBeTruthy();
  expect(screen.getByText(/captain/i)).toBeTruthy();
  expect(screen.getByText('Not at all likely')).toBeTruthy();
  expect(screen.getByText('Extremely likely')).toBeTruthy();
  expect(screen.getByLabelText('What went particularly well?')).toBeTruthy();
  expect(screen.getByLabelText('What could we improve?')).toBeTruthy();
 });

 it('requires all six ratings before submission',async()=>{
  const user=userEvent.setup();
  const onSubmit=vi.fn(async()=>undefined);
  render(<JourneyFeedbackForm journey={journey} onSubmit={onSubmit}/>);

  await user.click(screen.getByRole('button',{name:'Submit feedback'}));

  expect(onSubmit).not.toHaveBeenCalled();
  expect(screen.getByRole('alert').textContent).toBe('Please complete all six ratings.');
 });

 it('submits the approved numeric ratings, separate comments and explicit consent',async()=>{
  const user=userEvent.setup();
  const onSubmit=vi.fn(async()=>undefined);
  render(<JourneyFeedbackForm journey={journey} onSubmit={onSubmit}/>);

  await user.click(screen.getByLabelText('Booking experience 5 stars'));
  await user.click(screen.getByLabelText('Pace Shuttles recommendation 10'));
  await user.click(screen.getByLabelText('Operator and journey 4 stars'));
  await user.click(screen.getByLabelText('Captain 5 stars'));
  await user.click(screen.getByLabelText('Pickup location 3 stars'));
  await user.click(screen.getByLabelText('Destination 4 stars'));
  await user.type(screen.getByLabelText('What went particularly well?'),'Friendly captain.');
  await user.type(screen.getByLabelText('What could we improve?'),'Clearer pickup signs.');
  await user.click(screen.getByLabelText(/testimonial/i));
  await user.click(screen.getByRole('button',{name:'Submit feedback'}));

  expect(onSubmit).toHaveBeenCalledWith({
   bookingExperienceRating:5,
   nps:10,
   operatorRating:4,
   captainRating:5,
   pickupRating:3,
   destinationRating:4,
   wentWell:'Friendly captain.',
   couldImprove:'Clearer pickup signs.',
   testimonialConsent:true,
  });
  expect(screen.getByText('Thank you — your feedback has been submitted.')).toBeTruthy();
 });

 it('prevents a second submission while the first request is pending',async()=>{
  const user=userEvent.setup();
  let resolveSubmission:()=>void=()=>undefined;
  const onSubmit=vi.fn(()=>new Promise<void>(resolve=>{resolveSubmission=resolve}));
  render(<JourneyFeedbackForm journey={journey} onSubmit={onSubmit}/>);

  await user.click(screen.getByLabelText('Booking experience 5 stars'));
  await user.click(screen.getByLabelText('Pace Shuttles recommendation 10'));
  await user.click(screen.getByLabelText('Operator and journey 5 stars'));
  await user.click(screen.getByLabelText('Captain 5 stars'));
  await user.click(screen.getByLabelText('Pickup location 5 stars'));
  await user.click(screen.getByLabelText('Destination 5 stars'));
  await user.click(screen.getByRole('button',{name:'Submit feedback'}));

  const pending=screen.getByRole('button',{name:'Submitting…'}) as HTMLButtonElement;
  expect(pending.disabled).toBe(true);
  await user.click(pending);
  expect(onSubmit).toHaveBeenCalledTimes(1);
  resolveSubmission();
 });

 it('opens one deep-linked journey, persists success in the parent projection, and offers no second path after close',async()=>{
  window.history.replaceState({},'',`/customer?booking=${journey.booking_id}&feedback=1`);
  const submit=vi.fn(async()=>undefined);
  function Harness(){
   const flow=useJourneyFeedbackFlow([journey],[]);
   return <>{flow.selected?<JourneyFeedbackForm journey={flow.selected} onSubmit={async input=>{await submit(input);flow.markSubmitted(flow.selected!.booking_id)}} onClose={flow.close}/>:null}{!flow.hasFeedback(journey.booking_id)?<button onClick={()=>flow.open(journey)}>Rate journey</button>:null}</>;
  }
  const user=userEvent.setup();render(<Harness/>);
  expect(await screen.findByText('Two-minute journey feedback')).toBeTruthy();
  expect(screen.getAllByText('Two-minute journey feedback')).toHaveLength(1);
  for(const label of ['Booking experience 5 stars','Pace Shuttles recommendation 10','Operator and journey 5 stars','Captain 5 stars','Pickup location 5 stars','Destination 5 stars'])await user.click(screen.getByLabelText(label));
  await user.click(screen.getByRole('button',{name:'Submit feedback'}));
  expect(await screen.findByText('Thank you — your feedback has been submitted.')).toBeTruthy();
  await user.click(screen.getByRole('button',{name:'Close'}));
  expect(screen.queryByRole('button',{name:'Rate journey'})).toBeNull();
  expect(screen.queryByText('Two-minute journey feedback')).toBeNull();
 });

 it('keeps a dismissed deep-linked survey closed across production-equivalent fresh journey arrays',async()=>{
  window.history.replaceState({},'',`/customer?booking=${journey.booking_id}&feedback=1`);
  function Harness(){
   const [renderCount,setRenderCount]=React.useState(0);
   const flow=useJourneyFeedbackFlow([{...journey}],[]);
   return <>{flow.selected?<JourneyFeedbackForm journey={flow.selected} onSubmit={vi.fn(async()=>undefined)} onClose={flow.close}/>:null}<button onClick={()=>setRenderCount(value=>value+1)}>Refresh journeys {renderCount}</button>{!flow.hasFeedback(journey.booking_id)?<button onClick={()=>flow.open(journey)}>Rate journey</button>:null}</>;
  }
  const user=userEvent.setup();render(<Harness/>);
  expect(await screen.findByText('Two-minute journey feedback')).toBeTruthy();
  await user.click(screen.getByRole('button',{name:'Close feedback form'}));
  expect(screen.queryByText('Two-minute journey feedback')).toBeNull();
  await user.click(screen.getByRole('button',{name:/Refresh journeys/}));
  expect(screen.queryByText('Two-minute journey feedback')).toBeNull();
  expect(screen.getByRole('button',{name:'Rate journey'})).toBeTruthy();
 });
});
