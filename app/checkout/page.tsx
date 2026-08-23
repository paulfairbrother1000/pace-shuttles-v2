import { Suspense } from 'react';
import Checkout from '@/components/customer-checkout';

export default function Page(){
  return (
    <Suspense fallback={<main className="ps-checkout"><p>Loading your journey…</p></main>}>
      <Checkout/>
    </Suspense>
  );
}
