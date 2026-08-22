import { Suspense } from 'react'; import { AdminShell } from '@/components/ui'; import { Analytics } from '@/components/pages';
export default function Page(){return <Suspense><AdminShell title="Performance Analytics" subtitle="Deep performance insights across the Pace Shuttles network"><Analytics/></AdminShell></Suspense>}
