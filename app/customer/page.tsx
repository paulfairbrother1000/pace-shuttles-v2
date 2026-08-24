import Link from 'next/link';
import { Suspense } from 'react';
import { CustomerSearch } from '@/components/pages';

export default function Page(){
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
        <div className="ps-customer-title">
          <p className="eyebrow">Your Pace Shuttles account</p>
          <h1>My Journeys</h1>
          <p>Bookings, journey updates, refunds and support in one place.</p>
        </div>
        <Suspense fallback={<div className="card section">Loading your journeys…</div>}>
          <CustomerSearch/>
        </Suspense>
      </section>
    </main>
  );
}
