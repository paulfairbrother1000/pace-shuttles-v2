import { createClient } from '@supabase/supabase-js';
import { dispatchDueCustomerEmails } from '@/lib/customer-email';
import { createScheduledOperationsHandler } from '@/lib/scheduled-operations-handler';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = createScheduledOperationsHandler({
 env: process.env,
 now: () => new Date().toISOString(),
 createClient: (url, key, options) => {
  const client = createClient(url, key, options);
  return { rpc: (name, args) => client.rpc(name as never, args as never) };
 },
 dispatchDueCustomerEmails,
});
