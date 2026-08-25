import { NextRequest, NextResponse } from 'next/server';
import { createClient } from '@supabase/supabase-js';
import { dispatchDueCustomerEmails } from '@/lib/customer-email';
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export async function GET(req: NextRequest) {
  const expected = process.env.CRON_SECRET;
  const auth = req.headers.get('authorization');
  if (!expected || auth !== `Bearer ${expected}`) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return NextResponse.json({ error: 'Server configuration incomplete' }, { status: 500 });
  const supabase = createClient(url, key, { auth: { persistSession: false } });
  const { data, error } = await supabase.rpc('v2_system_run_scheduled_operations', { p_t72_limit: 100, p_t24_limit: 100 });
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  let emailResult={claimed:0,sent:0,failed:0};
  try{emailResult=await dispatchDueCustomerEmails(50)}catch(e:any){console.error('Customer email dispatch failed',e?.message||e)}
  return NextResponse.json({ ok: true, result: data, emails:emailResult });
}
