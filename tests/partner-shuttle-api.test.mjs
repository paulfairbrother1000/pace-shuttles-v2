import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const routePath='app/api/public/partner/shuttle-routes/route.ts';
const migrationPath='supabase/migrations/20260830220000_partner_catalogue_api.sql';
const hardeningPath='supabase/migrations/20260830224500_harden_partner_catalogue_api.sql';
const optimizationPath='supabase/migrations/20260830235000_optimize_partner_catalogue_api.sql';

test('partner shuttle API is a server-only authenticated V2 endpoint',()=>{
  assert.equal(existsSync(routePath),true,'V2 partner route handler must exist');
  const source=readFileSync(routePath,'utf8');
  assert.match(source,/x-pace-api-key/);
  assert.match(source,/SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(source,/v2_system_partner_shuttle_catalog/);
  assert.doesNotMatch(source,/operator_id|x-operator-key|bopvaaexicvdueidyvjd|pace-shuttles-v1/);
});

test('catalogue scopes canonical eligibility joins before scanning departures',()=>{
  assert.equal(existsSync(optimizationPath),true,'partner API optimization migration must exist');
  const sql=readFileSync(optimizationPath,'utf8');
  for(const table of ['vehicle_route_offers','vehicles','operators','operator_vehicle_types','route_vehicle_types','vehicle_availability_exceptions']){
    assert.match(sql,new RegExp(`pace_v2\\.${table}`));
  }
  assert.match(sql,/r\.country_id=v_partner\.country_id/);
  assert.match(sql,/rvt\.effective_from<=d\.scheduled_departure_ts/);
  assert.match(sql,/rvt\.effective_to is null or rvt\.effective_to>d\.scheduled_departure_ts/);
});

test('public endpoint rate-limits all callers before key authentication',()=>{
  const source=readFileSync(routePath,'utf8');
  assert.match(source,/v2_system_check_partner_api_rate_limit/);
  assert.match(source,/x-forwarded-for/);
  assert.match(source,/status:429/);
});

test('catalogue uses canonical vehicle eligibility and serialised rate limits',()=>{
  assert.equal(existsSync(hardeningPath),true,'partner API hardening migration must exist');
  const sql=readFileSync(hardeningPath,'utf8');
  assert.match(sql,/get_eligible_vehicle_offers\(d\.id\)/);
  assert.match(sql,/for update/i);
  assert.match(sql,/client_fingerprint_hash/i);
  assert.match(sql,/digest\(coalesce\(p_client_fingerprint,''\),'sha256'\)/i);
  assert.doesNotMatch(sql,/rvt\.effective_to is null/);
});

test('partner catalogue migration stores only key hashes and scopes access by country',()=>{
  assert.equal(existsSync(migrationPath),true,'partner catalogue migration must exist');
  const sql=readFileSync(migrationPath,'utf8');
  assert.match(sql,/create table pace_v2\.api_partners/i);
  assert.match(sql,/api_key_hash/i);
  assert.match(sql,/country_id uuid/i);
  assert.match(sql,/digest\(p_api_key,'sha256'\)/i);
  assert.match(sql,/published_at is not null/i);
  assert.match(sql,/d\.scheduled_departure_ts > now\(\)/i);
  assert.doesNotMatch(sql,/^\s*api_key\s+text/im,'raw API keys must never be stored');
  assert.match(sql,/revoke all on function public\.v2_system_partner_shuttle_catalog/i);
  assert.match(sql,/grant execute on function public\.v2_system_partner_shuttle_catalog\(text\) to service_role/i);
});
