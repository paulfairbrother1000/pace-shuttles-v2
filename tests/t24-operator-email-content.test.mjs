import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import ts from 'typescript';

async function loadBuilder(){
 const source=readFileSync(new URL('../lib/t24-operator-email.ts',import.meta.url),'utf8');
 const compiled=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
 return import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`);
}

const input={
 pickupName:'Nanny Cay Marina',destinationName:'The Soggy Dollar',departureDate:'Sunday, 20 September 2026',
 vehicles:[{vehicleType:'Speed Boat',vehicleName:'IrieVibez',captainName:'Stevie Steve'}],
 itinerary:[
  {journey:'Journey 1',route:'Nanny Cay Marina to The Soggy Dollar',pickupTime:'10:00 AM',arriveByTime:'9:45 AM'},
  {journey:'Journey 2',route:'The Soggy Dollar to Nanny Cay Marina',pickupTime:'2:00 PM',arriveByTime:'1:45 PM'}
 ],
 parties:[
  {party:'Birdshit party',vehicleName:'IrieVibez',passengers:[{name:'David Birdshit',category:'adult'},{name:'Jane Birdshit',category:'child'}]},
  {party:'Dryland party',vehicleName:'IrieVibez',passengers:[{name:'Dave Dryland',category:'infant'}]}
 ]
};

test('operator T-24 email uses clear tables and a party-grouped manifest',async()=>{
 const {buildT24OperatorEmail}=await loadBuilder();
 const email=buildT24OperatorEmail(input);
 assert.equal(email.subject,'Journey confirmed for Nanny Cay Marina to The Soggy Dollar tomorrow');
 assert.match(email.html,/>Journey<\/h2>/);
 assert.match(email.html,/>Scheduled vehicles and captains<\/h2>/);
 assert.match(email.html,/>Itinerary<\/h2>/);
 assert.match(email.html,/>Manifest<\/h2>/);
 assert.match(email.html,/<table/g);
 assert.match(email.html,/Birdshit party[\s\S]*David Birdshit[\s\S]*Adult/);
 assert.match(email.html,/Birdshit party[\s\S]*Jane Birdshit[\s\S]*Child/);
 assert.match(email.html,/Dryland party[\s\S]*Dave Dryland[\s\S]*Infant/);
 assert.doesNotMatch(email.html,/wpaul909@gmail\.com|07875330394|price|payment/i);
 assert.match(email.text,/Scheduled vehicles and captains/);
 assert.match(email.text,/IrieVibez — Speed Boat — Stevie Steve/);
});

test('operator T-24 email rejects incomplete operational data',async()=>{
 const {buildT24OperatorEmail}=await loadBuilder();
 assert.throws(()=>buildT24OperatorEmail({...input,vehicles:[]}),/vehicle/i);
 assert.throws(()=>buildT24OperatorEmail({...input,itinerary:[]}),/itinerary/i);
 assert.throws(()=>buildT24OperatorEmail({...input,parties:[]}),/party/i);
});
