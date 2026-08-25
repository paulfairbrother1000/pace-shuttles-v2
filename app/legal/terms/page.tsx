"use client";
import {useEffect,useState} from 'react';
import Link from 'next/link';
import {useSearchParams} from 'next/navigation';
import {getSupabaseBrowserClient} from '@/lib/supabase';

function safeReturnPath(value:string|null){
 if(!value)return '/book';
 try{
  const decoded=decodeURIComponent(value);
  return decoded.startsWith('/')&&!decoded.startsWith('//')?decoded:'/book';
 }catch{return '/book'}
}

export default function TermsPage(){
 const sp=useSearchParams(),country=sp.get('country'),returnTo=safeReturnPath(sp.get('returnTo'));const s=getSupabaseBrowserClient();const [terms,setTerms]=useState<any>(null),[msg,setMsg]=useState('');
 useEffect(()=>{if(!s||!country)return;void s.rpc('v2_public_country_terms_ref',{p_country_ref:country}).then(({data,error})=>{if(error||!data?.[0])setMsg(error?.message||'Terms not found');else setTerms(data[0])})},[s,country]);
 const returnLabel=returnTo.startsWith('/checkout')?'← Return to payment':'← Back';
 return <main className="ps-checkout"><header><Link href={returnTo}>{returnLabel}</Link><b>Pace Shuttles</b></header><section style={{maxWidth:900,margin:'32px auto'}}>{!country?<div className="ps-alert">Choose a journey to view the terms that apply to that country.</div>:!terms&&!msg?<p>Loading terms…</p>:msg?<div className="ps-alert">{msg}</div>:<><p className="eyebrow">{terms.country_name}</p><h1>{terms.title}</h1><p className="muted">Version {terms.version}</p><div style={{whiteSpace:'pre-wrap',lineHeight:1.65}}>{terms.terms_text}</div>{returnTo.startsWith('/checkout')&&<p style={{marginTop:32}}><Link className="ps-primary" href={returnTo}>Return to payment</Link></p>}</>}</section></main>;
}
