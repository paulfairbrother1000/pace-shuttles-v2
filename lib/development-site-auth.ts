export function isBasicAuthAuthorized(
  authorization: string | null,
  username: string,
  password: string,
): boolean {
  if (!authorization?.startsWith('Basic ')) return false;

  try {
    return atob(authorization.slice(6)) === `${username}:${password}`;
  } catch {
    return false;
  }
}

export function isDevelopmentAuthExemptPath(pathname: string): boolean {
  // API routes use their own authentication or are intentional integrations.
  // In particular, browser APIs use a Bearer token that cannot share the
  // Authorization header with this site's Basic Auth challenge.
  return pathname === '/api' || pathname.startsWith('/api/');
}
