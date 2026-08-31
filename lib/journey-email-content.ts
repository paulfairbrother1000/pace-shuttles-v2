export type TomorrowJourneyEmailInput = {
  firstName:string; countryName:string; pickupName:string; destinationName:string;
  departureLocalLabel:string; arrivalByLocalLabel:string; captainFullName:string;
  captainSurname:string; vehicleType:string; vehicleName:string;
  pickupDirectionsUrl:string; wetDestination:boolean;
};

export function buildTomorrowJourneyEmail(input:TomorrowJourneyEmailInput):{subject:string;text:string}{
  const wet = input.wetDestination
    ? `\n\nPlease prepare for a wet arrival\n\nThere is no mooring at ${input.destinationName}, so you will get wet when you disembark. Please bring a towel and any suitable clothing or footwear you may require.`
    : '';
  return {
    subject: `Your Journey to ${input.destinationName} is Tomorrow!`,
    text: `Hi ${input.firstName},\n\nThe time is almost upon us!\n\nYour journey from ${input.pickupName} to ${input.destinationName} at ${input.departureLocalLabel} is scheduled with Captain ${input.captainFullName} aboard the ${input.vehicleType} ${input.vehicleName}.\n\nPlease arrive at ${input.pickupName} no later than ${input.arrivalByLocalLabel}.\n\nGet directions to your pickup point\n${input.pickupDirectionsUrl}${wet}\n\nNeed to contact your captain on the day of travel?\n\nSign in to My Journeys (https://www.paceshuttles.com/customer), select this booking and open Help & Support. Choose Day of Travel, write your message and select Contact captain.\n\nYour captain will receive the message through Pace Shuttles. This secure conversation will remain available until four hours after your journey is completed.\n\nWe hope you have a wonderful journey to ${input.destinationName} with Captain ${input.captainSurname}.\n\nRegards,\nThe Pace Shuttles Team`
  };
}
