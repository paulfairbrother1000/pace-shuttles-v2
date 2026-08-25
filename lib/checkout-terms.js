export function canStartPayment(termsAccepted, busy) {
  return Boolean(termsAccepted) && !busy;
}

export function termsAcceptanceCopy(countryName, version) {
  return `I agree to the Pace Shuttles Client Terms & Conditions for ${countryName} (version ${version}).`;
}
