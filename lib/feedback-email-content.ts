export type FeedbackEmailInput={
  firstName:string;countryName:string;pickupName:string;destinationName:string;feedbackUrl:string;
};

const FEEDBACK_URL=/^https:\/\/www[.]paceshuttles[.]com\/customer\?(?=[^#]*\bbooking=[^&#]+)(?=[^#]*\bfeedback=1(?:&|$))[^#]+$/;

export function buildFeedbackEmail(input:FeedbackEmailInput):{subject:string;text:string}{
  if(!FEEDBACK_URL.test(input.feedbackUrl))throw new Error('Feedback URL must be a Pace Shuttles customer feedback deep link');
  return {
    subject:'Thank you for travelling with Pace Shuttles – one more thing…',
    text:`Hi ${input.firstName},\n\nThank you for travelling with Pace Shuttles. We hope you had a wonderful journey in ${input.countryName}, travelling from ${input.pickupName} to ${input.destinationName}.\n\nWe’d really appreciate your feedback about what went well and what we could improve. Your response will help Pace Shuttles, your operator, captain, pickup location and destination continue improving the experience provided to customers.\n\nShare your feedback\n${input.feedbackUrl}\n\nThe survey should take no more than two minutes.\n\nThank you again for choosing Pace Shuttles.\n\nRegards,\nThe Pace Shuttles Team`
  };
}
