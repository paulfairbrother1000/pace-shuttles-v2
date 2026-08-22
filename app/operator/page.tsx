import { Suspense } from 'react'; import { AdminShell } from '@/components/ui'; import { OperatorMobile } from '@/components/pages';
export default function Page(){return <Suspense><AdminShell title="Barefoot Dashboard" subtitle="Operator mobile-first operations"><OperatorMobile/></AdminShell></Suspense>}
