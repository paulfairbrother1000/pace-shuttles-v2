import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {availableCatalogue,visibleBookableJourneys,defaultJourneyPartySizes,setJourneyPartySize} from '../lib/customer-booking-view.ts';

test('catalogue exposes only geography backed by eligible public departures',()=>{
  const countries=[{id:'live-country'},{id:'empty-country'}];
  const destinations=[{id:'live-destination',country_id:'live-country'},{id:'empty-destination',country_id:'live-country'}];
  const pickups=[{id:'live-pickup',country_id:'live-country'},{id:'empty-pickup',country_id:'live-country'}];
  const departures=[{departure_id:'departure',country_id:'live-country',destination_id:'live-destination',pickup_id:'live-pickup'}];
  const catalogue=availableCatalogue(countries,destinations,pickups,departures);
  assert.deepEqual(catalogue.countries.map(x=>x.id),['live-country']);
  assert.deepEqual(catalogue.destinations.map(x=>x.id),['live-destination']);
  assert.deepEqual(catalogue.pickups.map(x=>x.id),['live-pickup']);
});

test('shows only journeys that can still become or already are bookable',()=>{
  const rows=[
    {departure_id:'offer',quote_status:'offer'},
    {departure_id:'checking',quote_status:'check_price'},
    {departure_id:'loading',quote_status:'loading_price'},
    {departure_id:'sold-out',quote_status:'sold_out_for_party'},
    {departure_id:'unavailable',quote_status:'unavailable'},
    {departure_id:'fairness',quote_status:'fairness_required'},
  ];
  assert.deepEqual(visibleBookableJourneys(rows).map(row=>row.departure_id),['offer','checking','loading']);
});

test('each journey defaults independently to one seat',()=>{
  assert.deepEqual(defaultJourneyPartySizes([{departure_id:'a'},{departure_id:'b'}]),{a:1,b:1});
});

test('changing one journey seat count does not change another journey',()=>{
  const current={a:1,b:1};
  assert.deepEqual(setJourneyPartySize(current,'b',3),{a:1,b:3});
});

test('calendar UI disables dates with no eligible journey',()=>{
  const source=readFileSync('components/customer-booking.tsx','utf8');
  assert.match(source,/disabled=\{!hasJourneys\}/);
});
