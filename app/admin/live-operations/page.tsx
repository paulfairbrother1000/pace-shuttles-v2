import { Suspense } from 'react'; import { AdminShell } from '@/components/ui'; import { LiveOperations } from '@/components/dashboard';
export default function Page(){return <Suspense><AdminShell title="Live Operations" subtitle="Real-time view of all journeys across the global network"><LiveOperations/></AdminShell></Suspense>}
