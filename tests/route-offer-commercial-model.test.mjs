import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {vehicleCapacity} from '../lib/vehicle-capacity.ts';

const adminPage=fs.readFileSync(new URL('../app/admin/operators/[id]/page.tsx',import.meta.url),'utf8');
const operatorDetail=fs.readFileSync(new URL('../components/operator-detail-route-offers.tsx',import.meta.url),'utf8');
const operatorDashboard=fs.readFileSync(new URL('../components/operator-dashboard.tsx',import.meta.url),'utf8');
const operatorPage=fs.readFileSync(new URL('../app/operator/page.tsx',import.meta.url),'utf8');
const adminVehicleEditor=fs.readFileSync(new URL('../components/admin-operator-vehicle-editor.tsx',import.meta.url),'utf8');
const vehicleEditorModel=fs.readFileSync(new URL('../lib/operator-vehicle-editor.ts',import.meta.url),'utf8');

test('site admin operator detail uses route offers and keeps vehicle creation non-commercial',()=>{
  assert.match(adminPage,/operator-detail-route-offers/);
  assert.match(operatorDetail,/AdminOperatorVehicleEditor/);
  assert.match(operatorDetail,/operatorId=\{id\}/);
  assert.doesNotMatch(operatorDetail,/Manage as Operator/);
  assert.doesNotMatch(operatorDetail,/manageAsOperator/);
  assert.doesNotMatch(operatorDetail,/title="Fleet"/);
  assert.doesNotMatch(operatorDetail,/title="Route Offers"/);
  assert.doesNotMatch(operatorDetail,/default_min_revenue_cents/);
});

test('vehicle capacity uses the physical capacity field',()=>{
  assert.equal(vehicleCapacity({capacity_seats:12,default_max_seats:99}),12);
  assert.equal(vehicleCapacity({capacity_seats:0,default_max_seats:99}),0);
});

test('route offer creation captures independent vehicle-route commercial inputs',()=>{
  assert.match(adminVehicleEditor,/operatorSaveVehicle/);
  assert.match(vehicleEditorModel,/vehicle_id/);
  assert.match(vehicleEditorModel,/route_id/);
  assert.match(vehicleEditorModel,/min_seats/);
  assert.match(vehicleEditorModel,/max_seats/);
  assert.match(vehicleEditorModel,/min_revenue_cents/);
});

test('operator self-service explains whole-journey economics',()=>{
  assert.match(operatorDashboard,/Route participation & commercial offers/);
  assert.match(operatorDashboard,/Minimum journey revenue/);
  assert.match(operatorPage,/minimum revenue required for this vehicle to perform the complete two-leg journey on this route/i);
  assert.match(operatorPage,/opposite direction is a separate Route Offer/i);
});
