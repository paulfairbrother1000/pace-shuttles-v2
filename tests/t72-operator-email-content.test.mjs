import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';
import ts from 'typescript';

const modulePath = new URL('../lib/t72-operator-email.ts', import.meta.url);

async function loadBuilder() {
  assert.equal(existsSync(modulePath), true, 'T-72 operator email builder is missing');
  const source = readFileSync(modulePath, 'utf8');
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  return import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`);
}

const journey = {
  journeyName: "St John's to Nikki Beach",
  departureDate: 'Sunday, 20 September 2026',
  departureTime: '10:00 am',
  t24Date: 'Saturday, 19 September 2026',
  t24Time: '10:00 am',
  operatorPortalUrl: 'https://www.paceshuttles.com/operator'
};

test('one under-consideration vehicle names its type, vehicle, captain and exact journey timing', async () => {
  const { buildT72OperatorEmail } = await loadBuilder();
  const email = buildT72OperatorEmail({
    ...journey,
    vehicles: [{ vehicleType: 'Speed Boat', vehicleName: 'Silver Lady', captainName: 'Stevie Williams' }]
  });

  assert.equal(email.subject, "Silver Lady is under consideration for St John's to Nikki Beach");
  assert.equal(email.text, `Your Speed Boat Silver Lady is under consideration for the following journey.

Date: Sunday, 20 September 2026
Time: 10:00 am
Journey: St John's to Nikki Beach
Assigned captain: Stevie Williams

Please let us know immediately on the Operator Portal if your resources are no longer available:
https://www.paceshuttles.com/operator

If your resources are still available, no action is required at this time. We shall confirm whether we require your vehicle on Saturday, 19 September 2026 at around 10:00 am.

Thanks,
The Pace Shuttles Team`);
});

test('several vehicles are consolidated into one operator email without losing captain detail', async () => {
  const { buildT72OperatorEmail } = await loadBuilder();
  const email = buildT72OperatorEmail({
    ...journey,
    vehicles: [
      { vehicleType: 'Speed Boat', vehicleName: 'Silver Lady', captainName: 'Stevie Williams' },
      { vehicleType: 'Speed Boat', vehicleName: 'Sea Sea Rider', captainName: 'James Williams' }
    ]
  });

  assert.equal(email.subject, "2 vehicles are under consideration for St John's to Nikki Beach");
  assert.match(email.text, /Speed Boat Silver Lady — Assigned captain: Stevie Williams/);
  assert.match(email.text, /Speed Boat Sea Sea Rider — Assigned captain: James Williams/);
  assert.equal((email.text.match(/Date:/g) || []).length, 1);
  assert.equal((email.text.match(/https:\/\/www\.paceshuttles\.com\/operator/g) || []).length, 1);
});

test('an under-consideration email cannot be built without a named captain', async () => {
  const { buildT72OperatorEmail } = await loadBuilder();
  assert.throws(() => buildT72OperatorEmail({
    ...journey,
    vehicles: [{ vehicleType: 'Speed Boat', vehicleName: 'Silver Lady', captainName: '' }]
  }), /captain/i);
});
