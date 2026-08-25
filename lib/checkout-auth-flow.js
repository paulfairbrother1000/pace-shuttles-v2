export function checkoutResumePath(quoteId){
  return `/checkout?q=${encodeURIComponent(quoteId)}&resume=1`;
}

export function checkoutAuthCopy(){
  return {
    primaryAction:'Continue to payment',
    heading:'Confirm your email to continue',
    emailAction:'Send confirmation email'
  };
}
