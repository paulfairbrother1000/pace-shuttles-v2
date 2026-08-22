import { Suspense } from 'react'; import { AdminShell } from '@/components/ui'; import { LiveOperations } from '@/components/dashboard';
export default function Page(){return <Suspense><AdminShell title="Journeys" subtitle="Search and manage journeys across the network"><LiveOperations/></AdminShell></Suspense>}
