'use client';
import React,{useEffect,useState} from 'react';
import {JourneyFeedbackForm,type FeedbackJourney} from './journey-feedback-form';
import {loadCustomerFeedbackBooking,loadCustomerFeedback,customerSubmitJourneyFeedback,type JourneyFeedbackInput} from '@/lib/data';
export function CustomerFeedback({bookingId}:{bookingId:string}){
 const [journey,setJourney]=useState<FeedbackJourney|null>(null);
 const [message,setMessage]=useState('Loading your questionnaire…');
 useEffect(()=>{
  let active=true;
  Promise.all([loadCustomerFeedbackBooking(bookingId),loadCustomerFeedback()]).then(([booking,feedback])=>{
   if(!active)return;
   if(booking.error||feedback.error){setMessage('We couldn’t load your questionnaire. Please refresh and try again.');return;}
   const row=booking.data?.[0];
   if(!row){setMessage('This questionnaire is not available for this account. Please sign in with the account used to book your journey.');return;}
   if(feedback.data.some(f=>f.booking_id===bookingId)){setMessage('Thank you — your feedback has already been submitted.');return;}
   if(String(row.departure_status).toLowerCase()!=='completed'){setMessage('Your questionnaire will be available when this journey is completed.');return;}
   setJourney(row as FeedbackJourney);
  }).catch(()=>{if(active)setMessage('We couldn’t load your questionnaire. Please refresh and try again.');});
  return()=>{active=false};
 },[bookingId]);
 async function submit(input:JourneyFeedbackInput){
  const result=await customerSubmitJourneyFeedback(bookingId,input);
  if(result.error)throw result.error;
 }
 return <section className="card section">{journey?<JourneyFeedbackForm key={bookingId} journey={journey} onSubmit={submit}/>:<p role="status">{message}</p>}</section>;
}
