import test from 'node:test';
import assert from 'node:assert/strict';

test('operator identity comes from active membership and signed-in account, not contact email', async () => {
  const moduleUrl = new URL('../lib/operator-identity.ts', import.meta.url);
  const {operatorIdentity} = await import(moduleUrl).catch(() => ({
    operatorIdentity: () => ({memberships: [], accountEmail: ''}),
  }));

  const identity = operatorIdentity({
    accountEmail: 'e2e.operator@paceshuttles.test',
    operatorMemberships: [
      {operator_id: 'barefoot-id', operator_name: 'Barefoot', role: 'operator_admin'},
    ],
    operatorContactEmail: 'paul.fairbrother@beyondservicemanagement.com',
  });

  assert.deepEqual(identity, {
    memberships: [{operatorName: 'Barefoot', roleLabel: 'Operator Admin'}],
    accountEmail: 'e2e.operator@paceshuttles.test',
  });
});

test('operator identity preserves each membership role pairing', async () => {
  const {operatorIdentity} = await import('../lib/operator-identity.ts');

  const identity = operatorIdentity({
    accountEmail: 'multi.operator@paceshuttles.test',
    operatorMemberships: [
      {operator_id: 'barefoot-id', operator_name: 'Barefoot', role: 'operator_admin'},
      {operator_id: 'antigua-id', operator_name: 'Antigua Boats', role: 'operator_user'},
    ],
  });

  assert.deepEqual(identity.memberships, [
    {operatorName: 'Barefoot', roleLabel: 'Operator Admin'},
    {operatorName: 'Antigua Boats', roleLabel: 'Operator User'},
  ]);
});

test('operator identity request failures produce an explicit error state', async () => {
  const identityModule = await import('../lib/operator-identity.ts');
  const operatorIdentityError = identityModule.operatorIdentityError ?? (() => '');

  assert.equal(
    operatorIdentityError({accountError: null, accessError: {message: 'Access unavailable'}}),
    'Access unavailable',
  );
});
