import { Suspense } from 'react';
import { AdminShell } from '@/components/ui';
import { Dashboard } from '@/components/dashboard';
export default function Page(){return <Suspense><AdminShell title="Global Dashboard" subtitle="Real-time overview of Pace Shuttles performance"><Dashboard/></AdminShell></Suspense>}
