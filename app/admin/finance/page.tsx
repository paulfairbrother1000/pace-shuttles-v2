import { Suspense } from 'react'; import { AdminShell } from '@/components/ui'; import { Finance } from '@/components/pages';
export default function Page(){return <Suspense><AdminShell title="Finance & Settlements" subtitle="Financial performance, commissions, settlements and payments"><Finance/></AdminShell></Suspense>}
