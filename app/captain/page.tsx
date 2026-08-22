import { Suspense } from 'react'; import { AdminShell } from '@/components/ui'; import { CaptainMobile } from '@/components/pages';
export default function Page(){return <Suspense><AdminShell title="Captain App" subtitle="Today's journeys and journey execution"><CaptainMobile/></AdminShell></Suspense>}
