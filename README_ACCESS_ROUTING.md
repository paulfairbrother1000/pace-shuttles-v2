# Pace Shuttles V2 — Role-aware access tranche

## Database
Already applied directly to the V2 Supabase project:
`current_access_context`

It creates `public.v2_current_access_context()` and grants it only to authenticated users.

The function returns the signed-in user's:
- platform role / site-admin status
- active operator memberships
- active captain links

## File to upload
Replace:
`components/auth.tsx`

## Behaviour
- `/admin/*` requires Site Admin.
- `/operator/*` requires an active operator membership.
- `/captain/*` requires an active captain record linked to the authenticated user.
- `/customer` requires only a signed-in account.
- `/`, `/book`, `/checkout` remain public so the existing browse + checkout/auth flow continues to work.
- An authenticated user who opens the wrong workspace is routed to an access-denied screen with a link to their own workspace.

No customer visual changes are included in this tranche.
