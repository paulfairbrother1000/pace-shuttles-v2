'use client';
import { FormEvent, ReactNode, useEffect, useState } from 'react';
import { usePathname } from 'next/navigation';
import { getSupabaseBrowserClient } from '@/lib/supabase';
import { CHECKOUT_OTP_LENGTH, isCheckoutOtpComplete, normalizeCheckoutOtp } from '@/lib/checkout-otp';

const PUBLIC=['/','/book','/checkout'];
type AccessContext={user_id:string|null;platform_role:string;is_site_admin:boolean;operator_ids:string[];operator_roles:string[];captain_ids:string[]};

export function AuthGate({children}:{children:ReactNode}){
 const path=usePathname();
 const isPublic=PUBLIC.some(x=>path===x||path.startsWith(x+'/'));
 const s=getSupabaseBrowserClient();
 const [ready,setReady]=useState(false),[session,setSession]=useState<any>(null),[access,setAccess]=useState<AccessContext|null>(null);
 const [email,setEmail]=useState(''),[password,setPassword]=useState(''),[msg,setMsg]=useState('');

 async function refreshAccess(current:any){
   setSession(current);
   if(!current||!s){setAccess(null);setReady(true);return;}
   const {data,error}=await s.rpc('v2_current_access_context');
   if(error){setMsg(error.message);setAccess(null)} else setAccess(Array.isArray(data)?data[0]||null:data);
   setReady(true);
 }
 useEffect(()=>{
   if(!s){setReady(true);return;}
   s.auth.getSession().then(({data})=>refreshAccess(data.session));
   const {data}=s.auth.onAuthStateChange((_e,x)=>{setReady(false);refreshAccess(x)});
   return()=>data.subscription.unsubscribe();
 },[s]);

 if(isPublic)return <>{children}</>;
 if(!ready)return <div className="login-wrap"><div className="card login-card"><h2>Loading Pace Shuttles…</h2></div></div>;
 if(!s||!session)return <Login email={email} setEmail={setEmail} password={password} setPassword={setPassword} msg={msg} setMsg={setMsg} s={s}/>;

 const allowed =
   path.startsWith('/admin') ? !!access?.is_site_admin :
   path.startsWith('/operator') ? !!access?.operator_ids?.length :
   path.startsWith('/captain') ? !!access?.captain_ids?.length :
   path.startsWith('/customer') ? true : true;

 if(!allowed)return <AccessDenied path={path} access={access} onSwitchAccount={async()=>{
   const {error}=await s.auth.signOut();
   if(error){setMsg(error.message);return;}
   setSession(null);setAccess(null);setReady(true);
 }}/>;
 return <>{children}</>;
}

function Login({email,setEmail,password,setPassword,msg,setMsg,s}:any){
 const [otp,setOtp]=useState(''),[otpSent,setOtpSent]=useState(false),[busy,setBusy]=useState(false);
 async function passwordLogin(e:FormEvent){e.preventDefault();setMsg('Signing in…');const {error}=await s.auth.signInWithPassword({email,password});setMsg(error?.message||'Signed in');}
 async function sendOtp(){
   if(!email){setMsg('Enter your email address first.');return;}
   setBusy(true);setMsg('Sending your verification code…');
   const {error}=await s.auth.signInWithOtp({email:email.trim(),options:{shouldCreateUser:false}});
   setBusy(false);
   if(error){setMsg(error.message);return;}
   setOtpSent(true);setMsg(`Enter the ${CHECKOUT_OTP_LENGTH}-digit code from your email.`);
 }
 async function verifyOtp(){
   if(!isCheckoutOtpComplete(otp))return;
   setBusy(true);setMsg('Checking your code…');
   const {error}=await s.auth.verifyOtp({email:email.trim(),token:normalizeCheckoutOtp(otp),type:'email'});
   setBusy(false);
   if(error){setMsg(error.message);return;}
   setMsg('Signed in');setOtp('');
 }
 return <div className="login-wrap"><div className="card login-card"><div className="brand login-brand"><div className="brandmark">P</div><div><b>Pace</b><small>SHUTTLES</small></div></div><h1>Sign in</h1><p>Sign in to continue.</p><form onSubmit={passwordLogin}><label htmlFor="pace-login-email">Email</label><input id="pace-login-email" autoComplete="email" type="email" value={email} onChange={(e:any)=>setEmail(e.target.value)} required/><label htmlFor="pace-login-password">Password</label><input id="pace-login-password" autoComplete="current-password" type="password" value={password} onChange={(e:any)=>setPassword(e.target.value)}/><button className="btn" type="submit">Sign in</button><button className="btn secondary" type="button" disabled={busy} onClick={sendOtp}>{busy?'Sending…':'Email me a verification code'}</button>{otpSent&&<><label htmlFor="pace-login-code">Verification code</label><input id="pace-login-code" inputMode="numeric" autoComplete="one-time-code" maxLength={CHECKOUT_OTP_LENGTH} placeholder={`${CHECKOUT_OTP_LENGTH}-digit code`} value={otp} onChange={(e:any)=>setOtp(normalizeCheckoutOtp(e.target.value))}/><button className="btn" type="button" disabled={busy||!isCheckoutOtpComplete(otp)} onClick={verifyOtp}>Verify and sign in</button><button className="btn secondary" type="button" disabled={busy} onClick={sendOtp}>Resend code</button></>}</form>{msg&&<div className="login-message">{msg}</div>}</div></div>
}
function AccessDenied({path,access,onSwitchAccount}:{path:string;access:AccessContext|null;onSwitchAccount:()=>Promise<void>}){
 const destination=access?.is_site_admin?'/admin':access?.operator_ids?.length?'/operator':access?.captain_ids?.length?'/captain':'/customer';
 return <div className="login-wrap"><div className="card login-card"><div className="brand login-brand"><div className="brandmark">P</div><div><b>Pace</b><small>SHUTTLES</small></div></div><h1>Access not available</h1><p>Your Pace Shuttles account is signed in, but it is not authorised for <b>{path}</b>.</p><button className="btn" type="button" onClick={onSwitchAccount}>Sign in with a different account</button><a className="btn secondary" href={destination}>Go to my workspace</a><a className="btn secondary" href="/book">Find a journey</a></div></div>
}
