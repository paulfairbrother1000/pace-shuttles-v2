import { Suspense } from 'react';
import { AdminShell, Section } from '@/components/ui';
import { OperatorDashboard } from '@/components/operator-dashboard';

export default function Page(){
  return (
    <Suspense>
      <AdminShell title="Operator Dashboard" subtitle="Journeys, availability, fleet, earnings and allocation transparency">
        <Section title="Route Offer pricing">
          <p className="data-note"><b>Minimum journey revenue</b> is the minimum revenue required for this vehicle to perform the complete two-leg journey on this route. You choose this figure for each vehicle and route, so efficient pricing can improve your competitive position in allocation. The opposite direction is a separate Route Offer.</p>
        </Section>
        <div style={{marginTop:12}}><OperatorDashboard/></div>
      </AdminShell>
    </Suspense>
  );
}
