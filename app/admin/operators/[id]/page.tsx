import { Suspense } from 'react'; import { AdminShell } from '@/components/ui'; import { OperatorDetail } from '@/components/pages';
export default async function Page({params}:{params:Promise<{id:string}>}){const {id}=await params; return <Suspense><AdminShell title="Operator" subtitle="Operator profile, setup, fleet and performance"><OperatorDetail id={id}/></AdminShell></Suspense>}
