// @vitest-environment jsdom
import React from 'react';
import {cleanup,render,screen,waitFor} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {afterEach,describe,expect,it,vi} from 'vitest';

vi.stubGlobal('React',React);

const signOut=vi.fn(async()=>({error:null}));
let currentSession:any={user:{id:'customer-user'}};
const getSession=vi.fn(async()=>({data:{session:currentSession}}));
const signInWithOtp=vi.fn(async()=>({data:{user:null,session:null},error:null}));
const verifyOtp=vi.fn(async()=>({data:{user:{id:'captain-user'},session:{user:{id:'captain-user'}}},error:null}));
const rpc=vi.fn(async()=>({
  data:{user_id:'customer-user',platform_role:'customer',is_site_admin:false,operator_ids:[],operator_roles:[],captain_ids:[]},
  error:null,
}));
const unsubscribe=vi.fn();
const onAuthStateChange=vi.fn(()=>({data:{subscription:{unsubscribe}}}));

vi.mock('next/navigation',()=>({usePathname:()=>'/operator'}));
vi.mock('@/lib/supabase',()=>({
  getSupabaseBrowserClient:()=>({auth:{getSession,onAuthStateChange,signOut,signInWithOtp,verifyOtp},rpc}),
}));

import {AuthGate} from './auth';

afterEach(()=>{cleanup();vi.clearAllMocks();currentSession={user:{id:'customer-user'}}});

describe('AuthGate account switching',()=>{
  it('signs out from an unauthorised route so another role can sign in on the same route',async()=>{
    render(<AuthGate><div>Operator workspace</div></AuthGate>);

    expect((await screen.findByText(/not authorised for/i)).textContent).toContain('/operator');
    const user=userEvent.setup();
    await user.click(screen.getByRole('button',{name:'Sign in with a different account'}));

    await waitFor(()=>expect(signOut).toHaveBeenCalledTimes(1));
  });

  it('accepts the emailed eight-digit code and verifies it on the requested role route',async()=>{
    currentSession=null;
    render(<AuthGate><div>Operator workspace</div></AuthGate>);

    const user=userEvent.setup();
    await user.type(await screen.findByRole('textbox'),'psfairbrother@hotmail.com');
    await user.click(screen.getByRole('button',{name:'Email me a verification code'}));
    const code=await screen.findByLabelText('Verification code');
    await user.type(code,'91150164');
    await user.click(screen.getByRole('button',{name:'Verify and sign in'}));

    expect(signInWithOtp).toHaveBeenCalledWith({email:'psfairbrother@hotmail.com',options:{shouldCreateUser:false}});
    expect(verifyOtp).toHaveBeenCalledWith({email:'psfairbrother@hotmail.com',token:'91150164',type:'email'});
  });
});
