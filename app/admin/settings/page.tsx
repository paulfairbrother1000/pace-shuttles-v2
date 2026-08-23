import { Suspense } from 'react'; import { AdminShell } from '@/components/ui'; import { Configuration } from '@/components/pages';
export default function Page(){return <Suspense><AdminShell title="Configuration" subtitle="Commercial rules, users, notifications and system health"><Configuration/></AdminShell></Suspense>}
