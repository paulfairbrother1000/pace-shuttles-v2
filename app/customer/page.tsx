import Link from 'next/link';
import { Suspense } from 'react';
import {CustomerFeedback} from '@/components/customer-feedback';
import { CustomerSearch } from '@/components/pages';

export default async function Page({searchParams}:{searchParams:Promise<{booking?:string;feedback?:string}>}){
  const params=await searchParams;
  const feedbackBooking=params.feedback==='1'&&typeof params.booking==='string'?params.booking:null;
  return (
    <main className="ps-customer-account">
      <header className="ps-customer-header">
        <Link className="ps-customer-brand" href="/book">Pace Shuttles</Link>
        <nav>
          <Link href="/book">Find a journey</Link>
          <Link className="active" href="/customer">My Journeys</Link>
        </nav>
      </header>

      <section className="ps-customer-content">
        {!feedbackBooking&&<div className="ps-customer-title">
          <p className="eyebrow">Your Pace Shuttles account</p>
          <h1>My Journeys</h1>
          <p>Bookings, journey updates, refunds and support in one place.</p>
        </div>}
        <Suspense fallback={<div className="card section">Loading your journeys…</div>}>
          {feedbackBooking?<CustomerFeedback bookingId={feedbackBooking}/>:<CustomerSearch/>}
        </Suspense>
      </section>
    </main>
  );
}
