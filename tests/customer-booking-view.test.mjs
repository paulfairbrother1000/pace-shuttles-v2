import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {availableCatalogue,availableJourneyDates,visibleBookableJourneys,visibleJourneyResults,journeySeatLimit,defaultJourneyPartySizes,setJourneyPartySize} from '../lib/customer-booking-view.ts';

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

test('a journey remains visible when the customer party no longer fits',()=>{
  const rows=[
    {departure_id:'selected',quote_status:'sold_out_for_party'},
    {departure_id:'already-full',quote_status:'sold_out_for_party'},
    {departure_id:'other',quote_status:'offer'},
  ];
  assert.deepEqual(visibleJourneyResults(rows,{selected:4,'already-full':1}).map(row=>row.departure_id),['selected','other']);
});

test('seat selector respects the live contiguous whole-party limit',()=>{
  assert.equal(journeySeatLimit({max_party_size:2}),2);
  assert.equal(journeySeatLimit({max_party_size:20}),12);
  assert.equal(journeySeatLimit({max_party_size:0}),12);
});

test('booking card explains an unavailable party without suggesting another journey replaced it',()=>{
  const source=readFileSync('components/customer-booking.tsx','utf8');
  assert.match(source,/Only .* seats remain together/);
  assert.match(source,/Choose a smaller party/);
  assert.match(source,/journeySeatLimit\(q\)/);
});

test('calendar UI disables dates with no eligible journey',()=>{
  const source=readFileSync('components/customer-booking.tsx','utf8');
  assert.match(source,/disabled=\{!hasJourneys\}/);
});

test('quick dates match the complete selected journey including pickup and type',()=>{
  const departures=[
    {country_id:'bvi',destination_id:'soggy',pickup_id:'a',local_departure_date:'2026-09-02',vehicle_types:[{id:'speedboat'}]},
    {country_id:'bvi',destination_id:'soggy',pickup_id:'b',local_departure_date:'2026-09-04',vehicle_types:[{id:'speedboat'}]},
    {country_id:'bvi',destination_id:'soggy',pickup_id:'a',local_departure_date:'2026-09-06',vehicle_types:[{id:'sailboat'}]},
    {country_id:'bvi',destination_id:'cooper',pickup_id:'a',local_departure_date:'2026-09-08',vehicle_types:[{id:'speedboat'}]},
  ];
  assert.deepEqual(availableJourneyDates(departures,{countryId:'bvi',destinationId:'soggy',pickupId:'a',vehicleTypeId:'speedboat'}),['2026-09-02']);
});

test('quick dates remain broad only for filters the customer has not selected',()=>{
  const departures=[
    {country_id:'bvi',destination_id:'soggy',pickup_id:'a',local_departure_date:'2026-09-02',vehicle_types:[{id:'speedboat'}]},
    {country_id:'bvi',destination_id:'cooper',pickup_id:'b',local_departure_date:'2026-09-04',vehicle_types:[{id:'sailboat'}]},
  ];
  assert.deepEqual(availableJourneyDates(departures,{countryId:'bvi'}),['2026-09-02','2026-09-04']);
});

test('route changes cannot search with an invalid stale date or vehicle type',()=>{
  const source=readFileSync('components/customer-booking.tsx','utf8');
  assert.match(source,/if\(vehicleType&&!types\.some\(type=>\(type\.id\|\|type\.name\)===vehicleType\)\)setVehicleType\(''\)/);
  assert.match(source,/if\(country&&\(!day\|\|\(datesRouteKey===routeKey&&dates\.includes\(day\)\)\)\)void searchJourneys\(\)/);
});

test('offered dates come from bookable search results rather than schedule rows alone',()=>{
  const source=readFileSync('components/customer-booking.tsx','utf8');
  assert.match(source,/setBookableDates\(current=>\{const next=availableJourneyDates\(visibleBookableJourneys\(rows\),\{\}\);return current\.join\('\|'\)===next\.join\('\|'\)\?current:next\}\)/);
  assert.match(source,/matchingJourneyDeps\.filter\(row=>dates\.includes\(row\.local_departure_date\)\)/);
});
