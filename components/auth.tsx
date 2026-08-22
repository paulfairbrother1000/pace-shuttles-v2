'use client';
import { FormEvent, ReactNode, useEffect, useState } from 'react';
import { getSupabaseBrowserClient } from '@/lib/supabase';

export function AuthGate({children}:{children:ReactNode}){
 const s=getSupabaseBrowserClient(); const [ready,setReady]=useState(false); const [session,setSession]=useState<any>(null); const [email,setEmail]=useState(''); const [password,setPassword]=useState(''); const [msg,setMsg]=useState('');
 useEffect(()=>{if(!s){setReady(true);return;} s.auth.getSession().then(({data})=>{setSession(data.session);setReady(true)}); const {data}=s.auth.onAuthStateChange((_e,x)=>setSession(x)); return()=>data.subscription.unsubscribe()},[]);
 if(!ready) return <div className="login-wrap"><div className="card login-card"><h2>Loading Pace Shuttles…</h2></div></div>;
 if(!s) return <>{children}</>;
 if(session) return <>{children}</>;
 async function passwordLogin(e:FormEvent){e.preventDefault();setMsg('Signing in…'); const {error}=await s!.auth.signInWithPassword({email,password}); setMsg(error?.message||'Signed in');}
 async function magic(){if(!email){setMsg('Enter your email address first.');return;} setMsg('Sending secure sign-in link…'); const {error}=await s!.auth.signInWithOtp({email,options:{emailRedirectTo:window.location.origin+'/admin'}}); setMsg(error?.message||'Check your email for the Pace Shuttles sign-in link.');}
 return <div className="login-wrap"><div className="card login-card"><div className="brand login-brand"><div className="brandmark">P</div><div><b>Pace</b><small>SHUTTLES</small></div></div><h1>V2 Administration</h1><p>Sign in to the Pace Shuttles V2 platform.</p><form onSubmit={passwordLogin}><label>Email</label><input type="email" value={email} onChange={e=>setEmail(e.target.value)} required/><label>Password</label><input type="password" value={password} onChange={e=>setPassword(e.target.value)}/><button className="btn" type="submit">Sign in</button><button className="btn secondary" type="button" onClick={magic}>Email me a secure sign-in link</button></form>{msg&&<div className="login-message">{msg}</div>}</div></div>
}
