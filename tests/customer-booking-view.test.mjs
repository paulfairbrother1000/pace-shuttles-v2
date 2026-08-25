import test from 'node:test';
import assert from 'node:assert/strict';
import {visibleBookableJourneys} from '../lib/customer-booking-view.ts';

test('shows only journeys that can still become or already are bookable',()=>{
  const rows=[
    {departure_id:'offer',quote_status:'offer'},
    {departure_id:'checking',quote_status:'check_price'},
    {departure_id:'loading',quote_status:'loading_price'},
    {departure_id:'sold-out',quote_status:'sold_out_for_party'},
    {departure_id:'unavailable',quote_status:'unavailable'},
    {departure_id:'fairness',quote_status:'fairness_required'},
  ];

  assert.deepEqual(
    visibleBookableJourneys(rows).map(row=>row.departure_id),
    ['offer','checking','loading'],
  );
});
