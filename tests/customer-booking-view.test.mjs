import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {availableCatalogue,availableJourneyDates,visibleBookableJourneys,visibleJourneyResults,journeysNeedingCapacityHydration,journeySeatLimit,journeyCapacityMessages,journeyBookingCardState,journeyPricePromotion,googleMapsEmbedUrl,defaultJourneyPartySizes,setJourneyPartySize} from '../lib/customer-booking-view.ts';

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

test('shows journeys that can be booked or displayed as sold out',()=>{
  const rows=[
    {departure_id:'offer',quote_status:'offer'},
    {departure_id:'checking',quote_status:'check_price'},
    {departure_id:'loading',quote_status:'loading_price'},
    {departure_id:'sold-out',quote_status:'sold_out_for_party'},
    {departure_id:'unavailable',quote_status:'unavailable'},
    {departure_id:'fairness',quote_status:'fairness_required'},
  ];
  assert.deepEqual(visibleBookableJourneys(rows).map(row=>row.departure_id),['offer','checking','loading','sold-out']);
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
  assert.deepEqual(visibleJourneyResults(rows,{selected:4,'already-full':1}).map(row=>row.departure_id),['selected','already-full','other']);
});

test('a genuinely sold-out journey disables booking while a smaller valid party remains selectable',()=>{
  assert.deepEqual(
    journeyBookingCardState({quote_status:'sold_out_for_party',remaining_seats_total:0,max_party_size:0},false),
    {soldOut:true,partyUnavailable:false,selectorDisabled:true,actionDisabled:true,actionLabel:'Sold out'},
  );
  assert.deepEqual(
    journeyBookingCardState({quote_status:'sold_out_for_party',remaining_seats_total:2,max_party_size:2},false),
    {soldOut:false,partyUnavailable:true,selectorDisabled:false,actionDisabled:true,actionLabel:'Choose a smaller party'},
  );
});

test('every journey missing authoritative capacity is hydrated before display',()=>{
  const rows=[
    {departure_id:'broad-search',quote_status:'check_price'},
    {departure_id:'dated-offer',quote_status:'offer'},
    {departure_id:'dated-sold-out',quote_status:'sold_out_for_party'},
    {departure_id:'complete',quote_status:'offer',remaining_seats_total:4,max_party_size:4},
  ];
  assert.deepEqual(journeysNeedingCapacityHydration(rows).map(row=>row.departure_id),['broad-search','dated-offer','dated-sold-out']);
});

test('seat selector respects the live contiguous whole-party limit',()=>{
  assert.equal(journeySeatLimit({max_party_size:2}),2);
  assert.equal(journeySeatLimit({max_party_size:20}),12);
  assert.equal(journeySeatLimit({max_party_size:0}),12);
});

test('capacity urgency distinguishes total seats from contiguous party size',()=>{
  assert.deepEqual(journeyCapacityMessages({remaining_seats_total:4,max_party_size:4}),['Only 4 seats remaining']);
  assert.deepEqual(journeyCapacityMessages({remaining_seats_total:3,max_party_size:2}),['Only 3 seats remaining','Maximum party size: 2']);
  assert.deepEqual(journeyCapacityMessages({remaining_seats_total:2,max_party_size:2}),['Only 2 seats remaining']);
  assert.deepEqual(journeyCapacityMessages({remaining_seats_total:15,max_party_size:12}),[]);
});

test('price promotion labels only live discounted offers as REDUCED',()=>{
  assert.equal(journeyPricePromotion({quote_status:'offer',discount_applied:true}),'REDUCED');
  assert.equal(journeyPricePromotion({quote_status:'offer',discount_applied:false}),null);
  assert.equal(journeyPricePromotion({quote_status:'loading_price',discount_applied:true}),null);
  assert.equal(journeyPricePromotion({quote_status:'sold_out_for_party',discount_applied:true}),null);
});

test('map embeds prefer valid coordinates and fall back to a location query',()=>{
  assert.equal(googleMapsEmbedUrl({latitude:17.074,longitude:-61.887}),'https://www.google.com/maps?q=17.074%2C-61.887&z=18&output=embed');
  assert.equal(googleMapsEmbedUrl({latitude:'17.074',longitude:'-61.887'}),'https://www.google.com/maps?q=17.074%2C-61.887&z=18&output=embed');
  assert.equal(googleMapsEmbedUrl({name:'Jolly Harbour',address1:'Jolly Harbour Marina',town:'Jolly Harbour',region:'St Marys',latitude:null,longitude:-61.887}),'https://www.google.com/maps?q=Jolly+Harbour%2C+Jolly+Harbour+Marina%2C+Jolly+Harbour%2C+St+Marys&z=18&output=embed');
  assert.equal(googleMapsEmbedUrl({name:'Boom',address1:'Gunpowder House',address2:'Dockyard Drive',town:'English Harbour',latitude:'not-a-number',longitude:-61.887}),'https://www.google.com/maps?q=Boom%2C+Gunpowder+House%2C+Dockyard+Drive%2C+English+Harbour&z=18&output=embed');
  assert.equal(googleMapsEmbedUrl({name:'',address:'',latitude:91,longitude:-61.887}),null);
  assert.equal(googleMapsEmbedUrl({latitude:17.074,longitude:-181}),null);
});

test('booking card explains an unavailable party without suggesting another journey replaced it',()=>{
  const source=readFileSync('components/customer-booking.tsx','utf8');
  assert.match(source,/Only .* seats remain together/);
  assert.match(source,/Choose a smaller party/);
  assert.match(source,/journeySeatLimit\(q\)/);
  assert.match(source,/journeyCapacityMessages\(q\)/);
});

test('checkout capacity migration reserves pending parties and serializes commits',()=>{
  const migration=readFileSync('supabase/migrations/20260901030000_checkout_capacity_reservations.sql','utf8');
  assert.match(migration,/pg_advisory_xact_lock/);
  assert.match(migration,/status='pending_payment'/);
  assert.match(migration,/qi\.expires_at>now\(\)/);
  assert.match(migration,/preliminary_vehicle_id/);
  assert.match(migration,/remaining_seats_total integer/);
  assert.match(migration,/reserved_seats/);
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
  assert.match(source,/vehicleType\s*&&[\s\S]*!types\.some\(\(type\) => \(type\.id \|\| type\.name\) === vehicleType\)/);
  assert.match(source,/country\s*&&[\s\S]*datesRouteKey === routeKey[\s\S]*void searchJourneys\(\)/);
});

test('offered dates come from bookable search results rather than schedule rows alone',()=>{
  const source=readFileSync('components/customer-booking.tsx','utf8');
  assert.match(source,/setBookableDates\(\(current\) =>[\s\S]*availableJourneyDates\(visibleBookableJourneys\(rows\), \{\}\)/);
  assert.match(source,/matchingJourneyDeps\.filter\(\(row\) =>\s*dates\.includes\(row\.local_departure_date\)/);
});
