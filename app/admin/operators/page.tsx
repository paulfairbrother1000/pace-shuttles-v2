import { Suspense } from 'react'; import { AdminShell } from '@/components/ui'; import { Operators } from '@/components/pages';
export default function Page(){return <Suspense><AdminShell title="Operators" subtitle="Manage and view operator performance and configuration"><Operators/></AdminShell></Suspense>}
