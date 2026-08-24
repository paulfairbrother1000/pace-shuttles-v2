import { Suspense } from 'react';
import { AdminShell } from '@/components/ui';
import { OperatorDashboard } from '@/components/operator-dashboard';

export default function Page(){
  return (
    <Suspense>
      <AdminShell title="Operator Dashboard" subtitle="Journeys, availability, fleet, earnings and allocation transparency">
        <OperatorDashboard/>
      </AdminShell>
    </Suspense>
  );
}
