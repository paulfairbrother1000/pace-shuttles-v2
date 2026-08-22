import type { Metadata } from 'next';
import './globals.css';
import { AuthGate } from '@/components/auth';

export const metadata: Metadata = {
  title: 'Pace Shuttles V2',
  description: 'Pace Shuttles V2 operations and booking platform'
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return <html lang="en"><body><AuthGate>{children}</AuthGate></body></html>;
}
