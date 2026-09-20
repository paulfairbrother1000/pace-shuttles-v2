import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import * as partnerApplication from '../lib/partner-application.ts';

test('the public header removes the redundant Book navigation control',()=>{
 const source=readFileSync('components/customer-booking.tsx','utf8');
 const nav=source.match(/<nav>[\s\S]*?<\/nav>/)?.[0]||'';
 assert.doesNotMatch(nav,/href="\/book"|>\s*Book\s*</);
 assert.match(nav,/href="\/"[\s\S]*>Home</);
 assert.match(nav,/href="\/customer"[\s\S]*>My journeys</);
});

test('journey results use one image-pair detail hint and retain clear mobile card separation',()=>{
 const source=readFileSync('components/customer-booking.tsx','utf8');
 const css=readFileSync('app/globals.css','utf8');
 assert.doesNotMatch(source,/Journey option|ps-journey-option/);
 assert.match(source,/className="ps-image-detail-hint"[^>]*>Click images for details</);
 assert.doesNotMatch(css,/content:'View details'/);
 assert.match(css,/\.ps-image-detail-hint\s*\{/);
 assert.match(css,/@media\(max-width:700px\)[\s\S]*\.ps-results\s*\{[^}]*gap:\s*2[04]px/i);
 assert.match(css,/@media\(max-width:700px\)[\s\S]*\.ps-journey\s*\{[^}]*box-shadow:/i);
});

test('partner network summary lists unique vehicle types and handles country grammar',()=>{
 const {partnerNetworkSnapshot}=partnerApplication;
 assert.equal(typeof partnerNetworkSnapshot,'function');
 assert.deepEqual(
  partnerNetworkSnapshot([{name:'Speed Boat'},{name:'Helicopter'},{name:'Speed Boat'},{name:'Seaplane'}],[{id:'ag'},{id:'vg'}]),
  {vehicleTypes:'Speed Boat, Helicopter and Seaplane',countryCount:2,countryLabel:'countries'}
 );
 assert.deepEqual(partnerNetworkSnapshot([{name:'Speed Boat'}],[{id:'ag'}]),{vehicleTypes:'Speed Boat',countryCount:1,countryLabel:'country'});
});

test('partner introduction uses live vehicle and country values with the approved invitation',()=>{
 const source=readFileSync('components/partner-application-form.tsx','utf8');
 assert.match(source,/partnerNetworkSnapshot\(types,countries\)/);
 assert.match(source,/networkReady\?/);
 assert.match(source,/world-class destinations and vehicle operators of all kinds/i);
 assert.match(source,/Our team will assess your application and be in touch regarding the next steps\./);
 assert.doesNotMatch(source,/Remaining publication details can be completed/);
});
