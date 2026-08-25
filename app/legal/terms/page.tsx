"use client";
import {useEffect,useState} from 'react';
import Link from 'next/link';
import {useSearchParams} from 'next/navigation';
import {getSupabaseBrowserClient} from '@/lib/supabase';

export default function TermsPage(){
 const sp=useSearchParams(),country=sp.get('country');const s=getSupabaseBrowserClient();const [terms,setTerms]=useState<any>(null),[msg,setMsg]=useState('');
 useEffect(()=>{if(!s||!country)return;void s.rpc('v2_public_country_terms',{p_country_id:country}).then(({data,error})=>{if(error||!data?.[0])setMsg(error?.message||'Terms not found');else setTerms(data[0])})},[s,country]);
 return <main className="ps-checkout"><header><Link href="/book">← Back</Link><b>Pace Shuttles</b></header><section style={{maxWidth:900,margin:'32px auto'}}>{!country?<div className="ps-alert">Choose a journey to view the terms that apply to that country.</div>:!terms&&!msg?<p>Loading terms…</p>:msg?<div className="ps-alert">{msg}</div>:<><p className="eyebrow">{terms.country_name}</p><h1>{terms.title}</h1><p className="muted">Version {terms.version}</p><div style={{whiteSpace:'pre-wrap',lineHeight:1.65}}>{terms.terms_text}</div></>}</section></main>;
}
