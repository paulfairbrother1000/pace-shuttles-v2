import test from 'node:test';
import assert from 'node:assert/strict';
import {existsSync,readFileSync} from 'node:fs';

const migrationPath='supabase/migrations/20260830133000_customer_country_availability.sql';
const checkoutGuardPath='supabase/migrations/20260830134000_enforce_country_pause_checkout.sql';

test('database contract centrally enforces eligible and unpaused public inventory',()=>{
  assert.equal(existsSync(migrationPath),true,'customer availability migration must exist');
  const sql=readFileSync(migrationPath,'utf8');
  assert.match(sql,/customer_availability_paused boolean not null default false/i);
  assert.match(sql,/country_customer_availability_audit/i);
  assert.match(sql,/v2_admin_set_country_customer_availability/i);
  assert.match(sql,/pace_v2\.is_site_admin\(\)/i);
  assert.match(sql,/customer_availability_paused is not true/i);
  for(const table of ['vehicle_route_offers','vehicles','operators','operator_vehicle_types','route_vehicle_types','vehicle_availability_exceptions']){
    assert.match(sql,new RegExp(`pace_v2\\.${table}`));
  }
  assert.match(sql,/create or replace view public\.v2_public_departures/i);
  assert.match(sql,/create or replace function public\.v2_public_quote/i);
  assert.match(sql,/create or replace function public\.v2_system_partner_shuttle_catalog/i);
  assert.match(sql,/revoke all on function public\.v2_admin_set_country_customer_availability/i);
});

test('country pause also blocks held quotes and payment races',()=>{
  assert.equal(existsSync(checkoutGuardPath),true,'checkout pause guard migration must exist');
  const sql=readFileSync(checkoutGuardPath,'utf8');
  assert.match(sql,/v2_customer_commit_quote/);
  assert.match(sql,/v2_customer_order_payment_context/);
  assert.match(sql,/v2_system_mark_stripe_paid/);
  assert.match(sql,/customer_availability_paused is not true/i);
  assert.match(sql,/Emergency country pause/i);
  assert.match(sql,/fulfillment_status='refund_required'/i);
  assert.match(sql,/for share of c/i);
  assert.match(sql,/o\.payment_status<>'paid'/i);
});
