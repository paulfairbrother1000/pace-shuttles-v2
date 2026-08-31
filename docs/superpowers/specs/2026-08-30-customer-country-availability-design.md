# Customer Country Availability Design

Countries, destinations, pickups, dates, vehicle types, routes, and departures are publicly discoverable only when at least one future departure has a currently eligible vehicle offer. Eligibility requires an active service-specific vehicle offer, active vehicle and operator, approved operator vehicle type, effective permitted route vehicle type, and no overlapping vehicle availability exception.

Site Admin has a separate emergency customer-availability pause at country level. Pausing requires a reason, immediately removes that country's inventory from public discovery and partner catalogues, and prevents new quotes and quote intents. Restoring also requires a reason. Every change records the administrator, timestamp, state, and reason.

The pause does not deactivate operational records or alter existing bookings. Existing customers retain access to My journeys, and Site Admin/operator operational views remain available.

The customer UI must derive every catalogue selector from eligible public departures and must not present “coming soon” or “no live journey” cards.
