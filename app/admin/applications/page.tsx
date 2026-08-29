import {Suspense} from 'react';import {AdminShell} from '@/components/ui';import {AdminPartnerApplications} from '@/components/admin-partner-applications';
export default function Page(){return <Suspense><AdminShell title="Partner Applications" subtitle="Review operator and destination applications"><AdminPartnerApplications/></AdminShell></Suspense>}
