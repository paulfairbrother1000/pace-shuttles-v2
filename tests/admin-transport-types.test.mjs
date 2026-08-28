import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import test from 'node:test';

test('configuration includes a complete transport type editor', async () => {
  const pages = await readFile(new URL('../components/pages.tsx', import.meta.url), 'utf8');
  const editor = await readFile(new URL('../components/admin-transport-types.tsx', import.meta.url), 'utf8').catch(() => '');

  assert.match(pages, /<AdminTransportTypes/);
  for (const field of ['code', 'name', 'description', 'picture_url', 'display_order', 'active']) {
    assert.match(editor, new RegExp(`name=["']${field}["']`), `missing ${field}`);
  }
  assert.match(editor, /type="file"/);
  assert.match(editor, /Upload tile image/);
});

test('transport type uploads use the existing images bucket and directory', async () => {
  const data = await readFile(new URL('../lib/data.ts', import.meta.url), 'utf8');
  assert.match(data, /adminUploadTransportTypeImage/);
  assert.match(data, /storage\.from\('images'\)\.upload/);
  assert.match(data, /transport-types/);
});

test('operator form loads table-driven transport types and current assignments', async () => {
  const form = await readFile(new URL('../components/admin-operator-form.tsx', import.meta.url), 'utf8');
  assert.match(form, /loadVehicleTypes/);
  assert.match(form, /loadOperatorVehicleTypes/);
  assert.match(form, /name="vehicle_type_ids"/);
  assert.match(form, /p_vehicle_type_ids/);
  assert.match(form, /Select at least one transport type/);
});

test('operator list displays assigned transport types', async () => {
  const pages = await readFile(new URL('../components/pages.tsx', import.meta.url), 'utf8');
  assert.match(pages, /Transport types/);
  assert.match(pages, /loadOperatorVehicleTypes/);
});

test('migration protects transport type management and in-use operator assignments', async () => {
  const dir = new URL('../supabase/migrations/', import.meta.url);
  const files = (await readdir(dir)).filter(x => x.endsWith('.sql'));
  const sql = (await Promise.all(files.map(x => readFile(new URL(x, dir), 'utf8')))).join('\n');

  assert.match(sql, /v2_admin_save_vehicle_type/);
  assert.match(sql, /pace_v2\.is_site_admin\(\)/);
  assert.match(sql, /p_vehicle_type_ids uuid\[\]/);
  assert.match(sql, /cannot remove transport type/i);
  assert.match(sql, /pace_v2\.vehicles/i);
  assert.match(sql, /transport-types/);
  assert.match(sql, /grant execute on function public\.v2_admin_save_vehicle_type[\s\S]*to authenticated/i);
});

test('customer type tiles retain the table-provided image', async () => {
  const booking = await readFile(new URL('../components/customer-booking.tsx', import.meta.url), 'utf8');
  assert.match(booking, /<Photo src=\{t\.picture_url\} alt=\{t\.name\}/);
  assert.match(booking, /className=\{`ps-type-card\$\{vehicleType===t\.id\?' selected':''\}`\}/);
  assert.match(booking, /onClick=\{\(\)=>setVehicleType\(vehicleType===t\.id\?'':t\.id\)\}/);
});
