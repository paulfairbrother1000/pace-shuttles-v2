import { createBrowserClient } from '@supabase/ssr';

let browserClient: ReturnType<typeof createBrowserClient> | null = null;

export function getSupabaseBrowserClient(){
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if(!url || !key || typeof window === 'undefined') return null;

  if(!browserClient){
    const client = createBrowserClient(url,key);
    const originalRpc = client.rpc.bind(client);

    // v2_public_quote returns result_status, while the customer booking UI uses
    // quote_status. Normalize only this RPC response at the browser boundary so
    // successful live quotes move cards out of "loading_price" and show prices.
    (client as any).rpc = (fn:string,args?:any,options?:any)=>{
      const request = originalRpc(fn as any,args,options);
      if(fn !== 'v2_public_quote') return request;
      return Promise.resolve(request).then((result:any)=>({
        ...result,
        data: Array.isArray(result.data)
          ? result.data.map((row:any)=>({
              ...row,
              quote_status: row.quote_status ?? row.result_status,
            }))
          : result.data,
      }));
    };

    browserClient = client;
  }

  // The browser talks only to Supabase's exposed public schema. Pace Shuttles V2
  // data is surfaced through tightly-scoped, security-invoker v2_* facade views.
  return browserClient;
}
