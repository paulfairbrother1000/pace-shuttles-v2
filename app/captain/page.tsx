import { Suspense } from 'react';
import { AdminShell } from '@/components/ui';
import { CaptainDashboard } from '@/components/captain-dashboard';

export default function Page(){
  return (
    <Suspense>
      <AdminShell title="Captain Dashboard" subtitle="Assigned journeys, manifests, passenger updates and voyage logs">
        <CaptainDashboard/>
      </AdminShell>
    </Suspense>
  );
}
