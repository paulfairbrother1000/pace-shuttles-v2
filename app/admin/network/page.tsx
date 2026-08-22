import { Suspense } from 'react'; import { AdminShell } from '@/components/ui'; import { Network } from '@/components/pages';
export default function Page(){return <Suspense><AdminShell title="Network Management" subtitle="Manage geography, pick ups, destinations, routes and services"><Network/></AdminShell></Suspense>}
