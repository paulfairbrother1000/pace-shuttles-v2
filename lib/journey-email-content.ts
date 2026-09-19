export type TomorrowJourneyEmailInput = {
  firstName:string; countryName:string; pickupName:string; destinationName:string;
  outboundPickupTimeLabel:string; outboundArrivalByTimeLabel:string;
  returnPickupTimeLabel:string; returnArrivalByTimeLabel:string;
  adultCount:number; childCount:number; infantCount:number;
  captainFullName:string; captainSurname:string; vehicleType:string;
  vehicleName:string; wetDestination:boolean;
};

export type CaptainPendingJourneyEmailInput = {
  firstName:string; pickupName:string; destinationName:string;
  departureDateLabel:string; departureLocalLabel:string; arrivalByLocalLabel:string;
  vehicleType:string; vehicleName:string; pickupDirectionsUrl:string;
  wetDestination:boolean;
};

export function buildTomorrowJourneyEmail(input:TomorrowJourneyEmailInput):{subject:string;text:string}{
  const wet = input.wetDestination
    ? `\n\n${input.destinationName} is a wet arrival destination, meaning you and your party will get wet. Please make sure you have appropriate clothes and a towel with this in mind.`
    : '';
  const adults=`${input.adultCount} ${input.adultCount===1?'adult':'adults'}`;
  const children=`${input.childCount} ${input.childCount===1?'child':'children'}`;
  const infants=`${input.infantCount} ${input.infantCount===1?'infant':'infants'}`;
  return {
    subject: `Reminder of Itinerary for ${input.pickupName} to ${input.destinationName} tomorrow`,
    text: `Hi ${input.firstName}\n\nYour Pace Shuttles return journey in ${input.countryName} between ${input.pickupName} and ${input.destinationName} is almost upon us.\n\nYour ${input.vehicleType} and captain have now been assigned to your trip.\n\n${input.vehicleType}:\n${input.vehicleName}\n\nCaptain: ${input.captainFullName}\n\nHere is a reminder of your itinerary details.\n\nParty of ${adults}, ${children} and ${infants}\n\nJourney 1: ${input.pickupName} to ${input.destinationName}\n\nPick up time: ${input.outboundPickupTimeLabel}\n\nPlease be at the ${input.vehicleType} by ${input.outboundArrivalByTimeLabel}\n\nJourney 2: ${input.destinationName} to ${input.pickupName}\n\nPick up time: ${input.returnPickupTimeLabel}\n\nPlease be at the ${input.vehicleType} by ${input.returnArrivalByTimeLabel}${wet}\n\nContacting Us\n\nOn the day of the journey, you can contact Captain ${input.captainSurname} if necessary using My Journeys > Help & Support > Contact the Captain in the Pace Shuttles portal.\n\nWe hope you have a great return trip to ${input.destinationName} with Captain ${input.captainSurname} onboard ${input.vehicleName}.\n\nBon voyage!\n\nThe Pace Shuttles Team`
  };
}

export function buildCaptainPendingJourneyEmail(input:CaptainPendingJourneyEmailInput):{subject:string;text:string}{
  const wet = input.wetDestination
    ? `\n\nPlease prepare for a wet arrival\n\nThere is no mooring at ${input.destinationName}, so you will get wet when you disembark. Please bring a towel and any suitable clothing or footwear you may require.`
    : '';
  return {
    subject: 'Your Pace Shuttles journey is tomorrow – captain confirmation pending',
    text: `Hi ${input.firstName},\n\nYour ${input.vehicleType} ${input.vehicleName} is scheduled for the following journey.\n\nDate: ${input.departureDateLabel}\nTime: ${input.departureLocalLabel}\nJourney: ${input.pickupName} to ${input.destinationName}\nVehicle: ${input.vehicleType} ${input.vehicleName}\nAssigned captain: To be confirmed\n\nWe are finalising the captain assignment and will send you an update as soon as it is confirmed. Your booking remains active and no action is required from you.\n\nPlease arrive at ${input.pickupName} no later than ${input.arrivalByLocalLabel}.\n\nGet directions to your pickup point\n${input.pickupDirectionsUrl}${wet}\n\nRegards,\nThe Pace Shuttles Team`
  };
}
