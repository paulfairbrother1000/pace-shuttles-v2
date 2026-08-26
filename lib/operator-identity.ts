export type OperatorMembershipIdentity = {
  operator_id: string;
  operator_name: string;
  role: string;
};

const roleLabel = (role: string) =>
  String(role || 'operator_user')
    .split('_')
    .map(part => part ? part[0].toUpperCase() + part.slice(1) : '')
    .join(' ');

export function operatorIdentity({
  accountEmail,
  operatorMemberships,
}: {
  accountEmail?: string | null;
  operatorMemberships?: OperatorMembershipIdentity[] | null;
}) {
  return {
    memberships: (operatorMemberships ?? []).map(membership => ({
      operatorName: membership.operator_name,
      roleLabel: roleLabel(membership.role),
    })),
    accountEmail: accountEmail ?? '',
  };
}

export function operatorIdentityError({
  accountError,
  accessError,
}: {
  accountError?: {message?: string} | null;
  accessError?: {message?: string} | null;
}) {
  return accessError?.message || accountError?.message || '';
}
