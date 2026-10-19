import { describe, expect, it } from 'vitest';
import { isBasicAuthAuthorized, isDevelopmentAuthExemptPath } from './development-site-auth';

describe('development site Basic Auth', () => {
  const validAuthorization = `Basic ${btoa('dev:99')}`;

  it('accepts the configured username and password', () => {
    expect(isBasicAuthAuthorized(validAuthorization, 'dev', '99')).toBe(true);
  });

  it('rejects missing, malformed, or incorrect credentials', () => {
    expect(isBasicAuthAuthorized(null, 'dev', '99')).toBe(false);
    expect(isBasicAuthAuthorized('Bearer token', 'dev', '99')).toBe(false);
    expect(isBasicAuthAuthorized('Basic %%%', 'dev', '99')).toBe(false);
    expect(isBasicAuthAuthorized(`Basic ${btoa('dev:wrong')}`, 'dev', '99')).toBe(false);
    expect(isBasicAuthAuthorized(`Basic ${btoa('other:99')}`, 'dev', '99')).toBe(false);
  });

  it('leaves API routes to their existing authentication and integration boundaries', () => {
    expect(isDevelopmentAuthExemptPath('/api/operations/run-scheduled')).toBe(true);
    expect(isDevelopmentAuthExemptPath('/api/operations/watch-scheduled')).toBe(true);
    expect(isDevelopmentAuthExemptPath('/api/stripe/webhook')).toBe(true);
    expect(isDevelopmentAuthExemptPath('/api/public/partner/shuttle-routes')).toBe(true);
    expect(isDevelopmentAuthExemptPath('/api/admin/refunds')).toBe(true);
    expect(isDevelopmentAuthExemptPath('/api/stripe/create-checkout-session')).toBe(true);
    expect(isDevelopmentAuthExemptPath('/')).toBe(false);
    expect(isDevelopmentAuthExemptPath('/admin')).toBe(false);
  });
});
