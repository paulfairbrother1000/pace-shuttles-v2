export const CHECKOUT_OTP_LENGTH = 8;

export const normalizeCheckoutOtp = (value:string) =>
  value.replace(/\D/g,'').slice(0,CHECKOUT_OTP_LENGTH);

export const isCheckoutOtpComplete = (value:string) =>
  normalizeCheckoutOtp(value).length === CHECKOUT_OTP_LENGTH;
