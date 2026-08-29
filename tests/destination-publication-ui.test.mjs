import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('network management separates destination draft saving from publication', async () => {
  const pages=await readFile(new URL('../components/pages.tsx',import.meta.url),'utf8');
  const data=await readFile(new URL('../lib/data.ts',import.meta.url),'utf8');
  assert.match(data,/adminSetDestinationPublished/);
  assert.match(data,/v2_admin_set_destination_published/);
  assert.match(pages,/Save draft/);
  assert.match(pages,/Publish destination/);
  assert.match(pages,/Unpublish destination/);
  assert.match(pages,/validateDestinationPublication/);
  assert.match(pages,/published_at/);
});
