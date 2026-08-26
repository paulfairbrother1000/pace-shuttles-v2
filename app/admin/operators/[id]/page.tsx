import { Suspense } from 'react';
import { AdminShell } from '@/components/ui';
import { OperatorDetailRouteOffers } from '@/components/operator-detail-route-offers';

export default async function Page({params,searchParams}:{params:Promise<{id:string}>;searchParams:Promise<{operator?:string}>}){
  const {id}=await params;
  const query=await searchParams;
  return <Suspense><AdminShell title="Operator" subtitle="Operator profile, fleet, route offers and performance"><OperatorDetailRouteOffers id={id} manageAsOperator={Boolean(query.operator)}/></AdminShell></Suspense>;
}
