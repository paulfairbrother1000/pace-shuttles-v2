import assert from 'node:assert/strict';
import {existsSync,readFileSync} from 'node:fs';
import test from 'node:test';

const migrationPath=new URL('../supabase/migrations/20260826250000_service_specific_vehicle_offers.sql',import.meta.url);
const migration=existsSync(migrationPath)?readFileSync(migrationPath,'utf8'):'';
const data=readFileSync(new URL('../lib/data.ts',import.meta.url),'utf8');
const pages=readFileSync(new URL('../components/pages.tsx',import.meta.url),'utf8');
const assignmentControls=readFileSync(new URL('../components/admin-service-assignment.tsx',import.meta.url),'utf8');

test('migration adds and safely backfills the required service foreign key',()=>{
 assert.ok(migration,'service-specific vehicle offer migration is missing');
 assert.match(migration,/add column service_id uuid/i);
 assert.match(migration,/count\(\*\)[\s\S]*<> 1/i);
 assert.match(migration,/raise exception 'Cannot backfill vehicle Route Offers:[^']*zero or multiple services'/i);
 assert.match(migration,/update pace_v2\.vehicle_route_offers[\s\S]*set service_id[\s\S]*pace_v2\.services/i);
 assert.match(migration,/foreign key \(service_id\) references pace_v2\.services\(id\)/i);
 assert.match(migration,/alter column service_id set not null/i);
});

test('migration enforces service-route consistency and current uniqueness by service',()=>{
 assert.match(migration,/drop index if exists pace_v2\.vehicle_route_offers_one_current_per_vehicle_route/i);
 assert.match(migration,/create unique index vehicle_route_offers_one_current_per_vehicle_service[\s\S]*\(vehicle_id,service_id\)[\s\S]*where effective_to is null/i);
 assert.match(migration,/create (?:or replace )?function pace_v2\.validate_vehicle_route_offer_service\(\)/i);
 assert.match(migration,/new\.route_id is distinct from v_service_route_id/i);
 assert.match(migration,/where s\.id=new\.service_id\s+for share;/i);
 assert.match(migration,/before insert or update of service_id,route_id on pace_v2\.vehicle_route_offers/i);
 assert.match(migration,/create (?:or replace )?function pace_v2\.prevent_offered_service_route_change\(\)/i);
 assert.match(migration,/before update of route_id on pace_v2\.services/i);
});

test('editor loaders expose active eligible service schedules and existing offer schedules',()=>{
 assert.match(migration,/v2_operator_load_vehicle_editor_routes\(\)[\s\S]*service_id uuid[\s\S]*days_of_week smallint\[\][\s\S]*departure_time time[\s\S]*timezone text/i);
 assert.match(migration,/from public\.v2_operator_vehicle_editor_routes er[\s\S]*join pace_v2\.services s on s\.route_id=er\.route_id and s\.active/i);
 assert.match(migration,/v2_operator_load_vehicle_editor_offers\(\)[\s\S]*service_id uuid[\s\S]*service_days_of_week smallint\[\][\s\S]*service_departure_time time[\s\S]*service_timezone text/i);
 assert.match(migration,/join pace_v2\.services s on s\.id=vro\.service_id and s\.route_id=vro\.route_id/i);
});

test('aggregate save derives and locks service routes and versions offers by service',()=>{
 assert.match(migration,/v_service_id uuid/i);
 assert.match(migration,/v_service_id := nullif\(v_offer->>'service_id',''\)::uuid/i);
 assert.match(migration,/from pace_v2\.services s[\s\S]*s\.id=v_service_id[\s\S]*s\.active[\s\S]*for share/i);
 assert.match(migration,/v_submitted_route_id is distinct from v_route_id/i);
 assert.match(migration,/er\.operator_id=v_operator_id[\s\S]*er\.route_id=v_route_id[\s\S]*er\.vehicle_type_id=v_vehicle_type_id/i);
 assert.match(migration,/group by a->>'service_id' having count\(\*\) > 1/i);
 assert.match(migration,/current_offer\.service_id=v_service_id/i);
 assert.match(migration,/v_existing\.service_id = v_service_id/i);
 assert.match(migration,/vehicle_id,service_id,route_id,preferred_captain_id/i);
});

test('updated RPCs are authenticated-only and retain operator or admin access checks',()=>{
 for(const signature of [
  'public.v2_operator_load_vehicle_editor_routes()',
  'public.v2_operator_load_vehicle_editor_offers()',
  'public.v2_operator_save_vehicle(jsonb)',
  'public.v2_admin_create_route_offer(uuid,uuid,integer,integer,integer,boolean,numeric,boolean,integer)'
 ]){
  const escaped=signature.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
  assert.match(migration,new RegExp(`revoke all on function ${escaped} from public, anon, authenticated;[\\s\\S]*grant execute on function ${escaped} to authenticated;`,'i'));
 }
 assert.match(migration,/auth\.uid\(\) is not null and pace_v2\.has_operator_access\(v\.operator_id\)/i);
 assert.match(migration,/if not pace_v2\.has_operator_access\(v_operator_id\) then raise exception 'operator access required'/i);
 assert.match(migration,/if not pace_v2\.is_site_admin\(\) then raise exception 'site admin required'/i);
});

test('Site Admin explicitly selects an eligible scheduled service and passes its id',()=>{
 assert.match(migration,/v2_admin_create_route_offer\(\s*p_vehicle_id uuid,\s*p_service_id uuid/i);
 assert.doesNotMatch(migration,/v2_admin_create_route_offer\(\s*p_vehicle_id uuid,\s*p_route_id uuid/i);
 assert.match(data,/adminCreateRouteOffer=\(a:\{[^}]*p_service_id:string/i);
 assert.match(pages,/\{rows:services\}=useLoad\(loadOperatorVehicleEditorRoutes\)/i);
 assert.match(pages,/\{rows:offers\}=useLoad\(loadOperatorVehicleEditorOffers\)/i);
 assert.match(assignmentControls,/service\.operator_id===operatorId&&service\.vehicle_type_id===vehicle\?\.vehicle_type_id/i);
 assert.match(assignmentControls,/aria-label="Assignment vehicle" value=\{vehicleId\}/i);
 assert.match(assignmentControls,/aria-label="Scheduled service" disabled=\{!vehicle\} value=\{serviceId\}/i);
 assert.match(pages,/adminCreateRouteOffer\(\{p_vehicle_id:vehicle\.id,p_service_id:service\.service_id/i);
 assert.doesNotMatch(pages,/services\.find\(z=>z\.active\)/i);
 assert.doesNotMatch(pages,/adminCreateRouteOffer\(\{p_vehicle_id:vehicle\.id,p_route_id:route\.id/i);
});

test('allocation eligibility matches offers to the requested scheduled service',()=>{
 const functionMatch=migration.match(/create or replace function pace_v2\.get_eligible_vehicle_offers\(p_departure_id uuid\)[\s\S]*?\n\$eligibility\$;/i);
 assert.ok(functionMatch,'service-scoped get_eligible_vehicle_offers replacement is missing');
 const eligibility=functionMatch[0];

 assert.match(eligibility,/returns table\(\s*departure_id uuid,\s*route_id uuid,\s*vehicle_route_offer_id uuid,\s*vehicle_id uuid,\s*operator_id uuid,\s*vehicle_type_id uuid,\s*normal_min_seats integer,\s*max_seats integer,\s*min_revenue_cents integer,\s*min_value_threshold_ratio numeric,\s*normal_base_seat_price_cents integer,\s*quality_score numeric,\s*effective_commission_bps integer,\s*effective_commission_source text\s*\)/i);
 assert.match(eligibility,/language sql\s+stable\s+security definer\s+set search_path\s*=\s*pace_v2,\s*public/i);
 assert.match(eligibility,/select\s+d\.id,\s*d\.service_id,\s*d\.route_id,\s*d\.scheduled_departure_ts,\s*d\.scheduled_arrival_ts/i);
 assert.match(eligibility,/join pace_v2\.vehicle_route_offers vro\s+on vro\.service_id\s*=\s*d\.service_id/i);
 assert.doesNotMatch(eligibility,/join pace_v2\.vehicle_route_offers vro\s+on vro\.route_id\s*=\s*d\.route_id/i);

 assert.match(eligibility,/d\.status not in \('cancelled','completed'\)/i);
 assert.match(eligibility,/vro\.active\s*=\s*true/i);
 assert.match(eligibility,/vro\.effective_from\s*<=\s*d\.scheduled_departure_ts/i);
 assert.match(eligibility,/vro\.effective_to is null or vro\.effective_to\s*>\s*d\.scheduled_departure_ts/i);
 assert.match(eligibility,/v\.active\s*=\s*true/i);
 assert.match(eligibility,/o\.active\s*=\s*true/i);
 assert.match(eligibility,/ovt\.status\s*=\s*'approved'/i);
 assert.match(eligibility,/from pace_v2\.route_vehicle_types rvt[\s\S]*rvt\.route_id\s*=\s*d\.route_id[\s\S]*rvt\.vehicle_type_id\s*=\s*v\.vehicle_type_id[\s\S]*rvt\.active\s*=\s*true[\s\S]*rvt\.effective_from\s*<=\s*d\.scheduled_departure_ts[\s\S]*rvt\.effective_to is null or rvt\.effective_to\s*>\s*d\.scheduled_departure_ts/i);
 assert.match(eligibility,/from pace_v2\.vehicle_availability_exceptions vae[\s\S]*vae\.vehicle_id\s*=\s*v\.id[\s\S]*vae\.start_ts\s*<[\s\S]*vae\.end_ts\s*>\s*d\.scheduled_departure_ts/i);
 assert.match(eligibility,/vro\.id as vehicle_route_offer_id/i);
 assert.match(eligibility,/c\.vehicle_route_offer_id/i);
});
