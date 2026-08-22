# Pace Shuttles V2 UI

Separate V2 Next.js application implementing the approved desktop/mobile interface direction while leaving V1 untouched.

## Run

```bash
npm install
cp .env.example .env.local
npm run dev
```

Open `http://localhost:3000/admin`.

## Implemented routes

- `/admin` Global Dashboard
- `/admin/live-operations` Live Operations
- `/admin/journeys/[id]` Journey Detail
- `/admin/analytics` Performance Analytics
- `/admin/operators` Operators
- `/admin/operators/[id]` Operator Detail
- `/admin/operators/barefoot?operator=barefoot` Admin-as-Operator mode
- `/admin/finance` Finance & Settlements
- `/admin/network` Network Management
- `/admin/support` Support & Administration
- `/admin/settings` Central Configuration
- `/operator` Operator mobile foundation
- `/captain` Captain mobile foundation
- `/customer` Customer search/booking foundation

## Architecture

- Next.js App Router + TypeScript
- Central design tokens in `app/globals.css`
- Responsive layouts: desktop-first analytics, mobile-first operations
- Supabase browser adapter configured for `pace_v2` schema
- Mock data currently used as a safe fallback while API read models are connected
- No allocation/price business logic is duplicated in the UI; production integration should call the V2 service/API contracts.

## Next integration steps

1. Connect Supabase Auth and role resolution (`site_admin`, operator membership, captain, customer).
2. Replace mock dashboard/read-model data with the existing `pace_v2.api_*` views and reporting RPCs.
3. Wire admin-as-operator mutations to the same operator APIs with an audited acting-admin identity.
4. Connect real-time departure updates through Supabase Realtime.
5. Connect Stripe-facing server actions/API routes; never expose service-role credentials client-side.
6. Add PWA/offline cache for captain/operator critical journey data.
