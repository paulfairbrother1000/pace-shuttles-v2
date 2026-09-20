import assert from 'node:assert/strict';
import {existsSync,readFileSync} from 'node:fs';
import test from 'node:test';

function pngSize(path){
  const file=readFileSync(path);
  assert.equal(file.subarray(1,4).toString(),'PNG');
  return [file.readUInt32BE(16),file.readUInt32BE(20)];
}

test('the supplied Pace Shuttles logo is used for browser and installed-app icons',()=>{
  const manifest=readFileSync('app/manifest.ts','utf8');
  const layout=readFileSync('app/layout.tsx','utf8');

  assert.match(layout,/applicationName:\s*'Pace Shuttles'/);
  assert.match(layout,/manifest:\s*'\/manifest\.webmanifest'/);
  assert.deepEqual(pngSize('app/icon.png'),[512,512]);
  assert.deepEqual(pngSize('app/apple-icon.png'),[180,180]);
  assert.deepEqual(pngSize('public/icons/pace-shuttles-192.png'),[192,192]);
  assert.deepEqual(pngSize('public/icons/pace-shuttles-512.png'),[512,512]);
  assert.equal(existsSync('app/favicon.ico'),true);
  assert.match(manifest,/pace-shuttles-192\.png/);
  assert.match(manifest,/pace-shuttles-512\.png/);
  assert.match(manifest,/purpose:\s*'any'/);
  assert.match(manifest,/purpose:\s*'maskable'/);
});
