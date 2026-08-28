import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('Journeys opens network management instead of duplicating Live Operations', async () => {
  const page = await readFile(new URL('../app/admin/journeys/page.tsx', import.meta.url), 'utf8');
  assert.match(page, /import \{ Network \} from '@\/components\/pages'/);
  assert.match(page, /<Network\s*\/>/);
  assert.doesNotMatch(page, /LiveOperations/);
});

test('network management has a dedicated compact mobile layout', async () => {
  const page = await readFile(new URL('../components/pages.tsx', import.meta.url), 'utf8');
  const css = await readFile(new URL('../app/globals.css', import.meta.url), 'utf8');
  assert.match(page, /className="network-management"/);
  assert.match(page, /className="grid-4 mobile-kpi-grid"/);
  assert.match(css, /@media\(max-width:760px\)[\s\S]*?\.network-management \.mobile-kpi-grid\{grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
  assert.match(css, /\.network-management \.table-scroll\{overflow-x:auto/);
});
