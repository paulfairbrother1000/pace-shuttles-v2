import type { Metadata } from 'next';
import './globals.css';
import './customer-light.css';
import { AuthGate } from '@/components/auth';

export const metadata: Metadata = {
  applicationName: 'Pace Shuttles',
  title: 'Pace Shuttles V2',
  description: 'Pace Shuttles V2 operations and booking platform',
  manifest: '/manifest.webmanifest'
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return <html lang="en"><body><AuthGate>{children}</AuthGate></body></html>;
}
