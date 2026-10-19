import { NextResponse, type NextRequest } from 'next/server';
import { isBasicAuthAuthorized, isDevelopmentAuthExemptPath } from './lib/development-site-auth';

export function middleware(req: NextRequest) {
  const password = process.env.DEV_SITE_PASSWORD;
  const pathname = req.nextUrl.pathname;

  if (
    password &&
    !isDevelopmentAuthExemptPath(pathname) &&
    !isBasicAuthAuthorized(
      req.headers.get('authorization'),
      process.env.DEV_SITE_USERNAME ?? 'dev',
      password,
    )
  ) {
    return new NextResponse('Please sign in to view the Pace Shuttles development site.', {
      status: 401,
      headers: {
        'WWW-Authenticate': 'Basic realm="Pace Shuttles development", charset="UTF-8"',
        'Cache-Control': 'no-store',
      },
    });
  }

  return NextResponse.next();
}

export const config = {
  matcher: ['/:path*'],
};
