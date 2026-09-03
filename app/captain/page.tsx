import { Suspense } from 'react';
import { AdminShell } from '@/components/ui';
import { CaptainDashboard } from '@/components/captain-dashboard';

export default async function Page({searchParams}:{searchParams?:Promise<{tab?:string|string[]}>}){
  const params=searchParams?await searchParams:{};
  const requested=Array.isArray(params.tab)?params.tab[0]:params.tab;
  return (
    <Suspense>
      <AdminShell title="Captain Dashboard" subtitle="Today’s duties, passenger communications, planning and journey history">
        <CaptainDashboard initialTab={requested==='general'?'general':'today'}/>
      </AdminShell>
    </Suspense>
  );
}
