import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import ts from 'typescript';

async function loadData(client){
 const source=readFileSync(new URL('../lib/data.ts',import.meta.url),'utf8')
  .replace("import { getSupabaseBrowserClient } from './supabase';","const getSupabaseBrowserClient=()=>globalThis.__adminQualityClient;")
  .replace("import { buildGeographyImagePath, type GeographyKind } from './admin-geography';","type GeographyKind='country'|'pickup'|'destination'; const buildGeographyImagePath=()=>'';");
 const compiled=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
 globalThis.__adminQualityClient=client;
 return import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}#${Math.random()}`);
}

function query(result,calls,table){
 const chain={
  select(columns){calls.push(['select',table,columns]);return chain},
  limit(limit){calls.push(['limit',table,limit]);return chain},
  order(column,options){calls.push(['order',table,column,options]);return chain},
  then(resolve){return Promise.resolve(result).then(resolve)},
 };
 return chain;
}

test('Finance loaders retain predecessor feedback and distinct evidence view contracts',async()=>{
 const calls=[];
 const feedback={id:'feedback-1',comment:'Predecessor comment',attribution:'operator',reviewed_at:'2030-01-01T00:00:00Z'};
 const evidence=[{id:'evidence-1',feedback_id:'feedback-1'},{id:'evidence-2',feedback_id:'feedback-1'}];
 const client={from(table){calls.push(['from',table]);return query({data:table==='v2_admin_customer_feedback'?[feedback]:evidence,error:null},calls,table)},rpc:async()=>({data:null,error:null})};
 const data=await loadData(client);

 assert.deepEqual(await data.loadAdminCustomerFeedback(),{data:[feedback],error:null});
 assert.deepEqual(await data.loadAdminQualityEvidence(),{data:evidence,error:null});
 assert.deepEqual(calls,[
  ['from','v2_admin_customer_feedback'],['select','v2_admin_customer_feedback','*'],['limit','v2_admin_customer_feedback',1000],['order','v2_admin_customer_feedback','created_at',{ascending:true}],
  ['from','v2_admin_quality_evidence'],['select','v2_admin_quality_evidence','*'],['limit','v2_admin_quality_evidence',1000],['order','v2_admin_quality_evidence','occurred_at',{ascending:true}],
 ]);
});

test('dedicated recent-quality loader forwards real page offsets without changing Finance shapes',async()=>{
 const calls=[];
 const page={items:[{id:'feedback-26'}],total:40,offset:25,limit:25};
 const client={from(){throw new Error('recent paging must not read predecessor Finance views')},rpc:async(name,args)=>{calls.push([name,args]);return {data:page,error:null}}};
 const data=await loadData(client);

 assert.deepEqual(await data.loadAdminRecentQualityPage(25,25),{data:[page],error:null});
 assert.deepEqual(calls,[['v2_site_admin_quality_evidence_page',{p_offset:25,p_limit:25}]]);
});
