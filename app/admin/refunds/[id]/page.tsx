import {Suspense} from 'react';
import {AdminShell} from '@/components/ui';
import {AdminRefundAction} from '@/components/admin-refund-action';
export default async function Page({params}:{params:Promise<{id:string}>}){
 const {id}=await params;
 return <AdminShell title="Refund action" subtitle="Review, approve and execute, or decline a customer refund"><Suspense fallback={<p>Loading refund…</p>}><AdminRefundAction id={id}/></Suspense></AdminShell>;
}
