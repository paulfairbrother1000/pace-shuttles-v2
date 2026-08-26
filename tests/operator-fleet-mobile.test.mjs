import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('mobile operator fleet shows all boats in a vertically scrollable list', async () => {
  const css = await readFile(new URL('../app/globals.css', import.meta.url), 'utf8');
  assert.match(
    css,
    /@media\(max-width:900px\)[\s\S]*?\.fleet-list\{display:grid;[^}]*max-height:[^}]*overflow-y:auto/,
  );
});
