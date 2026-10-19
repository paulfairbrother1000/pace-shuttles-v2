import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';

test('new route creation includes vehicle type and recurring season schedule',async()=>{
 const pages=await readFile(new URL('../components/pages.tsx',import.meta.url),'utf8');
 const data=await readFile(new URL('../lib/data.ts',import.meta.url),'utf8');
 const migration=await readFile(new URL('../supabase/migrations/20261019010000_create_scheduled_route_atomically.sql',import.meta.url),'utf8');

 assert.match(pages,/FormField label="Pickup"/);
 assert.match(pages,/FormField label="Destination"/);
 assert.match(pages,/FormField label="Vehicle type"/);
 assert.match(pages,/Departure time/);
 assert.match(pages,/Season starts/);
 assert.match(pages,/Season ends/);
 assert.match(pages,/adminCreateScheduledRoute/);
 assert.match(data,/v2_admin_create_scheduled_route/);
 assert.match(migration,/v2_admin_create_route\(/);
 assert.match(migration,/v2_admin_set_route_vehicle_type\(/);
 assert.match(migration,/v2_admin_create_service\(/);
});
