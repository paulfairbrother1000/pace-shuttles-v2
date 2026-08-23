import { createBrowserClient } from '@supabase/ssr';

export function getSupabaseBrowserClient(){
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if(!url || !key) return null;
  // The browser talks only to Supabase's exposed public schema. Pace Shuttles V2
  // data is surfaced through tightly-scoped, security-invoker v2_* facade views.
  return createBrowserClient(url,key);
}
