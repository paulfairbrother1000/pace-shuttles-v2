import { createBrowserClient } from '@supabase/ssr';

let browserClient: ReturnType<typeof createBrowserClient> | null = null;

export function getSupabaseBrowserClient(){
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if(!url || !key || typeof window === 'undefined') return null;

  // Keep one browser client for the lifetime of the page. A stable client identity
  // prevents React effects that depend on the client from retriggering on render.
  if(!browserClient) browserClient = createBrowserClient(url,key);

  // The browser talks only to Supabase's exposed public schema. Pace Shuttles V2
  // data is surfaced through tightly-scoped, security-invoker v2_* facade views.
  return browserClient;
}
