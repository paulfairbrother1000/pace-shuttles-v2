import { Suspense } from 'react'; import { AdminShell } from '@/components/ui'; import { Network } from '@/components/pages';
export default function Page(){return <Suspense><AdminShell title="Journeys" subtitle="Manage countries, pickup locations, destinations, routes and services"><Network/></AdminShell></Suspense>}
