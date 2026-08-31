import { NextRequest, NextResponse } from 'next/server';
import { dispatchDueCustomerEmails } from '@/lib/customer-email';

type SchedulerClient = {
  rpc: (name: string, args?: Record<string, unknown>) => PromiseLike<{
    data: unknown;
    error: { message: string } | null;
  }>;
};

type ScheduledOperationsDependencies = {
  env: NodeJS.ProcessEnv;
  now: () => string;
  createClient: (url: string, key: string, options: { auth: { persistSession: boolean } }) => SchedulerClient;
  dispatchDueCustomerEmails: typeof dispatchDueCustomerEmails;
};

export function createScheduledOperationsHandler(deps: ScheduledOperationsDependencies) {
  return async function scheduledOperations(req: NextRequest | Request) {
    const expected = deps.env.CRON_SECRET;
    const auth = req.headers.get('authorization');
    if (!expected || auth !== `Bearer ${expected}`) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
    const url = deps.env.NEXT_PUBLIC_SUPABASE_URL;
    const key = deps.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!url || !key) return NextResponse.json({ error: 'Server configuration incomplete' }, { status: 500 });
    const supabase = deps.createClient(url, key, { auth: { persistSession: false } });
    const { data, error } = await supabase.rpc('v2_system_run_scheduled_operations', { p_t72_limit: 100, p_t24_limit: 100 });
    if (error) return NextResponse.json({ error: error.message }, { status: 500 });
    const { error: t24Error } = await supabase.rpc('v2_system_schedule_t24_journey_notifications', { p_as_of: deps.now() });
    if (t24Error) return NextResponse.json({ error: t24Error.message }, { status: 500 });
    const { error: feedbackError } = await supabase.rpc('v2_system_schedule_feedback_requests', { p_as_of: deps.now(), p_limit: 100 });
    if (feedbackError) return NextResponse.json({ error: feedbackError.message }, { status: 500 });
    let emailResult = { claimed: 0, sent: 0, failed: 0 };
    try {
      emailResult = await deps.dispatchDueCustomerEmails(25);
    } catch (error: unknown) {
      console.error('Customer email dispatch failed', error instanceof Error ? error.message : error);
      return NextResponse.json({ error: 'Customer email dispatch failed' }, { status: 503 });
    }
    return NextResponse.json({ ok: true, result: data, emails: emailResult });
  };
}
