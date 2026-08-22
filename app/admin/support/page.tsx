import { Suspense } from 'react'; import { AdminShell } from '@/components/ui'; import { Support } from '@/components/pages';
export default function Page(){return <Suspense><AdminShell title="Support & Administration" subtitle="Support inbox, tickets, settings and platform administration"><Support/></AdminShell></Suspense>}
