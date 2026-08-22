import { Suspense } from 'react'; import { AdminShell } from '@/components/ui'; import { CustomerSearch } from '@/components/pages';
export default function Page(){return <Suspense><AdminShell title="Find a Journey" subtitle="Search and book Pace Shuttles"><CustomerSearch/></AdminShell></Suspense>}
