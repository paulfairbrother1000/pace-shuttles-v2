import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import test from 'node:test';

test('operator creation uses one complete form instead of sequential prompts', async () => {
  const pages = await readFile(new URL('../components/pages.tsx', import.meta.url), 'utf8');
  const form = await readFile(new URL('../components/admin-operator-form.tsx', import.meta.url), 'utf8').catch(() => '');

  assert.match(pages, /<AdminOperatorForm/);
  assert.doesNotMatch(pages, /const name=window\.prompt\('Operator name'\)/);
  for (const field of ['name','email','admin_email','contact_email','notification_email','phone','address1','address2','country_id','region_id','locality_id','town','region','postal_code','logo_url','cancellation_policy_id','white_label_member','active']) {
    assert.match(form, new RegExp(`name=["']${field}["']`), `missing ${field}`);
  }
  assert.match(form, /type="file"/);
  assert.match(form, /accept="image\/jpeg,image\/png,image\/webp,image\/gif"/);
});

test('operator details reuse the complete form for editing', async () => {
  const detail = await readFile(new URL('../components/operator-detail-route-offers.tsx', import.meta.url), 'utf8');
  assert.match(detail, /<AdminOperatorForm[^>]*operator=\{operator\}/);
  assert.doesNotMatch(detail, /window\.prompt\('Operator admin email'/);
});

test('operator logo uploads use the existing images bucket', async () => {
  const data = await readFile(new URL('../lib/data.ts', import.meta.url), 'utf8');
  assert.match(data, /adminUploadOperatorLogo/);
  assert.match(data, /storage\.from\('images'\)\.upload/);
  assert.match(data, /operator-logos/);
});

test('protected operator save migration persists every editable field', async () => {
  const dir = new URL('../supabase/migrations/', import.meta.url);
  const files = (await readdir(dir)).filter(x => x.endsWith('.sql'));
  const sql = (await Promise.all(files.map(x => readFile(new URL(x, dir), 'utf8')))).join('\n');

  assert.match(sql, /v2_admin_save_operator/);
  assert.match(sql, /pace_v2\.is_site_admin\(\)/);
  for (const field of ['admin_email','contact_email','notification_email','phone','address1','address2','postal_code','logo_url','white_label_member','cancellation_policy_id']) {
    assert.match(sql, new RegExp(field), `migration missing ${field}`);
  }
  assert.match(sql, /operator-logos/);
  assert.match(sql, /revoke all on function public\.v2_admin_save_operator[\s\S]*from public/);
  assert.match(sql, /grant execute on function public\.v2_admin_save_operator[\s\S]*to authenticated/);
});
