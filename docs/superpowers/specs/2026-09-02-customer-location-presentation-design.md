# Customer location presentation design

## Objective

Simplify journey cards and make pickup and destination details attractive, recognisable and useful. Customers should understand the two locations immediately, be encouraged by their imagery, and be able to inspect a map and obtain directions without losing their place in the booking flow.

## Journey cards

- Remove the two `View details` image labels.
- Remove the duplicate pickup and destination detail buttons beneath the route information.
- Permanently overlay only the relevant location name on each image.
- Keep each image as a button that opens the corresponding location panel.
- Preserve accessible button titles and image alternative text so removing visible instructional labels does not remove context for assistive technology.

For example, a Jolly Harbour to Boom card shows `Jolly Harbour` on the pickup image and `Boom` on the destination image.

## Location panel

- Retain the existing in-page modal interaction so customers do not lose their selected journey, date or party size.
- Restyle the modal to match the light customer interface: white background, navy headings, slate body text, blue actions, light borders, rounded corners and subtle shadow.
- Keep the location photograph prominent for aspiration and recognition.
- Present the location type, name, description, address, arrival information, telephone number and website when available.
- Place an embedded Google Maps view beneath the location information.
- Provide a prominent `Get directions` action that opens the location's validated Google Maps directions URL in a new tab.

## Map data and fallback

- Build the embedded map from the location's stored latitude and longitude using a Google Maps embed URL that does not require a new application API key.
- Accept only finite coordinates within valid latitude and longitude ranges.
- If either coordinate is absent or invalid, omit the map frame and continue showing the photograph and location information.
- Show the `Get directions` action only when a validated directions URL is available.
- Give the map a meaningful title for accessibility and lazy-load it to avoid delaying the booking page.

## Responsive behaviour

- Desktop uses a spacious photo-and-information presentation with the map spanning the useful content width below.
- Mobile stacks the photograph, information and map vertically.
- Location names remain visible on journey images without hover, including touch devices.

## Security and privacy

- Do not accept arbitrary iframe sources from database content.
- Construct the iframe source solely from validated numeric coordinates.
- Retain the existing validation and safe new-tab handling for external directions and website links.

## Verification

- Unit-test map URL creation for valid, missing, non-numeric and out-of-range coordinates.
- Regression-test that journey cards render location names and no longer render the removed visible detail labels/buttons.
- Run the complete automated test suite and production build.
- Verify desktop and mobile production behaviour: correct image names, modal styling, photograph, embedded map, directions action and state preservation after closing the panel.
