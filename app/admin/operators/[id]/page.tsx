import { Suspense } from 'react';
import { AdminShell } from '@/components/ui';
import { OperatorDetailRouteOffers } from '@/components/operator-detail-route-offers';

export default async function Page({params}:{params:Promise<{id:string}>}){
  const {id}=await params;
  return <Suspense><AdminShell title="Operator" subtitle="Operator setup, fleet, route participation and commercial settings"><OperatorDetailRouteOffers id={id}/></AdminShell></Suspense>;
}
