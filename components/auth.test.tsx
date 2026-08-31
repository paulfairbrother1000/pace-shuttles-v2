// @vitest-environment jsdom
import React from 'react';
import {cleanup,render,screen,waitFor} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,describe,expect,it,vi} from 'vitest';

vi.stubGlobal('React',React);

const signOut=vi.fn(async()=>({error:null}));
const getSession=vi.fn(async()=>({data:{session:{user:{id:'customer-user'}}}}));
const rpc=vi.fn(async()=>({
  data:{user_id:'customer-user',platform_role:'customer',is_site_admin:false,operator_ids:[],operator_roles:[],captain_ids:[]},
  error:null,
}));
const unsubscribe=vi.fn();
const onAuthStateChange=vi.fn(()=>({data:{subscription:{unsubscribe}}}));

vi.mock('next/navigation',()=>({usePathname:()=>'/operator'}));
vi.mock('@/lib/supabase',()=>({
  getSupabaseBrowserClient:()=>({auth:{getSession,onAuthStateChange,signOut},rpc}),
}));

import {AuthGate} from './auth';

afterEach(()=>{cleanup();vi.clearAllMocks()});

describe('AuthGate account switching',()=>{
  it('signs out from an unauthorised route so another role can sign in on the same route',async()=>{
    render(<AuthGate><div>Operator workspace</div></AuthGate>);

    expect((await screen.findByText(/not authorised for/i)).textContent).toContain('/operator');
    const user=userEvent.setup();
    await user.click(screen.getByRole('button',{name:'Sign in with a different account'}));

    await waitFor(()=>expect(signOut).toHaveBeenCalledTimes(1));
  });
});
