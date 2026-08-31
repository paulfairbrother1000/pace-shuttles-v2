'use client';

import React,{useEffect,useRef,useState} from 'react';
import type {JourneyFeedbackInput} from '@/lib/data';

export type FeedbackJourney={
 booking_id:string;
 route_name?:string|null;
 pickup_name?:string|null;
 destination_name?:string|null;
 scheduled_departure_ts?:string|null;
};

type Props={
 journey:FeedbackJourney;
 onSubmit:(feedback:JourneyFeedbackInput)=>Promise<void>;
 onClose?:()=>void;
};

type RatingKey='bookingExperienceRating'|'nps'|'operatorRating'|'captainRating'|'pickupRating'|'destinationRating';
type Ratings=Partial<Record<RatingKey,number>>;

export function useJourneyFeedbackFlow(journeys:FeedbackJourney[],feedback:Array<{booking_id:string}>){
 const [selected,setSelected]=useState<FeedbackJourney|null>(null);
 const [submitted,setSubmitted]=useState<Set<string>>(()=>new Set());
 const processedDeepLinks=useRef<Set<string>>(new Set());
 const hasFeedback=(bookingId:string)=>submitted.has(bookingId)||feedback.some(row=>row.booking_id===bookingId);
 useEffect(()=>{
  const params=new URLSearchParams(window.location.search);
  const bookingId=params.get('booking');
  if(params.get('feedback')!=='1'||!bookingId||processedDeepLinks.current.has(bookingId))return;
  if(hasFeedback(bookingId)){processedDeepLinks.current.add(bookingId);return;}
  const journey=journeys.find(row=>row.booking_id===bookingId);
  if(journey){processedDeepLinks.current.add(bookingId);setSelected(current=>current?.booking_id===bookingId?current:journey);}
 },[journeys,feedback,submitted]);
 return {
  selected,
  open:(journey:FeedbackJourney)=>{if(!hasFeedback(journey.booking_id))setSelected(journey)},
  close:()=>setSelected(null),
  hasFeedback,
  markSubmitted:(bookingId:string)=>setSubmitted(current=>new Set(current).add(bookingId)),
 };
}

const starQuestions:[RatingKey,string,string][]=[
 ['bookingExperienceRating','How would you rate your Pace Shuttles booking experience?','Booking experience'],
 ['operatorRating','How would you rate the operator and journey?','Operator and journey'],
 ['captainRating','How would you rate your captain?','Captain'],
 ['pickupRating','How would you rate the pickup location?','Pickup location'],
 ['destinationRating','How would you rate the destination?','Destination'],
];

function StarRating({name,question,label,value,onChange}:{name:RatingKey;question:string;label:string;value?:number;onChange:(value:number)=>void}){
 return <fieldset className="feedback-question">
  <legend>{question}<span aria-hidden="true"> *</span></legend>
  <div className="feedback-rating-row" role="radiogroup" aria-label={label}>
   {[1,2,3,4,5].map(rating=><label className={value===rating?'selected':''} key={rating}>
    <input type="radio" name={name} value={rating} checked={value===rating} onChange={()=>onChange(rating)} aria-label={`${label} ${rating} ${rating===1?'star':'stars'}`}/>
    <span aria-hidden="true">★</span><small>{rating}</small>
   </label>)}
  </div>
 </fieldset>;
}

export function JourneyFeedbackForm({journey,onSubmit,onClose}:Props){
 const [ratings,setRatings]=useState<Ratings>({});
 const [wentWell,setWentWell]=useState('');
 const [couldImprove,setCouldImprove]=useState('');
 const [testimonialConsent,setTestimonialConsent]=useState(false);
 const [submitting,setSubmitting]=useState(false);
 const [submitted,setSubmitted]=useState(false);
 const [error,setError]=useState('');
 const setRating=(key:RatingKey,value:number)=>setRatings(current=>({...current,[key]:value}));

 const submit=async(event:React.FormEvent)=>{
  event.preventDefault();
  if(submitting||submitted)return;
  const complete=ratings.bookingExperienceRating!=null&&ratings.nps!=null&&ratings.operatorRating!=null&&ratings.captainRating!=null&&ratings.pickupRating!=null&&ratings.destinationRating!=null;
  if(!complete){setError('Please complete all six ratings.');return;}
  setError('');setSubmitting(true);
  try{
   await onSubmit({
    bookingExperienceRating:ratings.bookingExperienceRating!,nps:ratings.nps!,operatorRating:ratings.operatorRating!,captainRating:ratings.captainRating!,pickupRating:ratings.pickupRating!,destinationRating:ratings.destinationRating!,
    wentWell:wentWell.trim(),couldImprove:couldImprove.trim(),testimonialConsent,
   });
   setSubmitted(true);
  }catch(reason){setError(reason instanceof Error?reason.message:'Feedback could not be submitted. Please try again.');}
  finally{setSubmitting(false);}
 };

 if(submitted)return <section className="journey-feedback-confirmation" aria-live="polite">
  <h3>Thank you — your feedback has been submitted.</h3>
  <p>Your response will help improve future Pace Shuttles journeys.</p>
  {onClose?<button className="btn secondary" type="button" onClick={onClose}>Close</button>:null}
 </section>;

 return <form className="journey-feedback-form" onSubmit={submit} noValidate>
  <div className="feedback-form-head">
   <div><p className="eyebrow">Two-minute journey feedback</p><h2>{journey.route_name||'Tell us about your journey'}</h2></div>
   {onClose?<button className="modal-close" type="button" onClick={onClose} aria-label="Close feedback form">×</button>:null}
  </div>
  <p className="feedback-journey-context"><b>{journey.pickup_name||'Pickup location'}</b><span aria-hidden="true">→</span><b>{journey.destination_name||'Destination'}</b></p>
  <p className="data-note">All six ratings are required. Your comments and testimonial permission are optional.</p>

  <StarRating name="bookingExperienceRating" question={starQuestions[0][1]} label={starQuestions[0][2]} value={ratings.bookingExperienceRating} onChange={value=>setRating('bookingExperienceRating',value)}/>

  <fieldset className="feedback-question feedback-nps">
   <legend>How likely are you to recommend Pace Shuttles to a friend?<span aria-hidden="true"> *</span></legend>
   <div className="feedback-nps-scale" role="radiogroup" aria-label="Pace Shuttles recommendation">
    {Array.from({length:11},(_,score)=><label className={ratings.nps===score?'selected':''} key={score}><input type="radio" name="nps" value={score} checked={ratings.nps===score} onChange={()=>setRating('nps',score)} aria-label={`Pace Shuttles recommendation ${score}`}/><span>{score}</span></label>)}
   </div>
   <div className="feedback-nps-endpoints"><span><b>0</b><span>Not at all likely</span></span><span><b>10</b><span>Extremely likely</span></span></div>
  </fieldset>

  {starQuestions.slice(1).map(([name,question,label])=><StarRating name={name} question={question} label={label} value={ratings[name]} onChange={value=>setRating(name,value)} key={name}/>)}

  <label className="form-field"><span>What went particularly well?</span><textarea aria-label="What went particularly well?" value={wentWell} onChange={event=>setWentWell(event.target.value)} maxLength={3000} placeholder="Tell us what made the journey work well."/></label>
  <label className="form-field"><span>What could we improve?</span><textarea aria-label="What could we improve?" value={couldImprove} onChange={event=>setCouldImprove(event.target.value)} maxLength={3000} placeholder="Tell us what would make the experience better."/></label>
  <label className="feedback-consent"><input type="checkbox" checked={testimonialConsent} onChange={event=>setTestimonialConsent(event.target.checked)} aria-label="Testimonial permission"/><span>I give Pace Shuttles permission to use my submitted comments as a testimonial.</span></label>
  {error?<p className="action-error" role="alert">{error}</p>:null}
  <button className="btn feedback-submit" type="submit" disabled={submitting}>{submitting?'Submitting…':'Submit feedback'}</button>
 </form>;
}
