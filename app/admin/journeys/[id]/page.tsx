import { Suspense } from 'react'; import { AdminShell } from '@/components/ui'; import { JourneyDetail } from '@/components/pages';
export default async function Page({params}:{params:Promise<{id:string}>}){const {id}=await params; return <Suspense><AdminShell title="Journey Detail" subtitle="Operations, passengers, allocation and financials"><JourneyDetail id={id}/></AdminShell></Suspense>}
