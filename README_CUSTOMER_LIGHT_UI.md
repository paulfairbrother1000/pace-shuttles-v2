# Pace Shuttles V2 — Customer Light UI tranche

Upload these folders over the repository root and commit to `main`.

## Changed files

- `app/customer-light.css`
  - Removes dark/navy page backgrounds from customer-facing booking and checkout.
  - Retains the V1-style photographic country/destination/pick-up cards.
  - Makes filters, journey results, checkout controls and summaries light/high-contrast.
  - Adds a light customer-account theme for My Journeys.
  - Does not change Site Admin, Operator or Captain operational UI.

- `app/layout.tsx`
  - Imports the customer-only light-theme stylesheet after `globals.css`, so the existing dark customer overrides are safely superseded without disturbing operational styles.

- `app/customer/page.tsx`
  - Removes `AdminShell` from the customer My Journeys page.
  - Gives customers a dedicated light header with Find a Journey / My Journeys navigation.
  - Reuses the existing `CustomerSearch` booking-management functionality.

## Existing checkout behaviour deliberately retained

The current checkout component already:
- stores the quote and passenger details in browser local storage,
- sends the magic-link return URL back to the exact checkout,
- restores passenger details after authentication,
- refreshes an expired quote without forcing data re-entry,
- does not reserve seats before payment.

No database migration is required for this tranche.
