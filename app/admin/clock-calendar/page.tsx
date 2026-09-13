import {Suspense} from 'react';import {AdminShell} from '@/components/ui';import {AdminClockCalendar} from '@/components/admin-clock-calendar';
export default function Page(){return <Suspense><AdminShell title="Clock, Calendar & Triggers" subtitle="Observe and control scheduled journey operations"><AdminClockCalendar/></AdminShell></Suspense>}
