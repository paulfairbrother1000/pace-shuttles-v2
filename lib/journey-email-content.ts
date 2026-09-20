export type TomorrowJourneyEmailInput = {
  firstName:string; countryName:string; pickupName:string; destinationName:string;
  outboundPickupTimeLabel:string; outboundArrivalByTimeLabel:string;
  returnPickupTimeLabel:string; returnArrivalByTimeLabel:string;
  adultCount:number; childCount:number; infantCount:number;
  captainFullName:string; captainSurname:string; vehicleType:string;
  vehicleName:string; wetDestination:boolean; pickupArrivalNotes:string;
  pickupDirectionsUrl:string;
};

export type CaptainPendingJourneyEmailInput = {
  firstName:string; pickupName:string; destinationName:string;
  departureDateLabel:string; departureLocalLabel:string; arrivalByLocalLabel:string;
  vehicleType:string; vehicleName:string; pickupDirectionsUrl:string;
  wetDestination:boolean;
};

const escapeHtml=(value:string)=>value.replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]||ch));

function passengerSummary(input:Pick<TomorrowJourneyEmailInput,'adultCount'|'childCount'|'infantCount'>){
  const groups=[
    [input.adultCount,input.adultCount===1?'adult':'adults'],
    [input.childCount,input.childCount===1?'child':'children'],
    [input.infantCount,input.infantCount===1?'infant':'infants']
  ] as const;
  const present=groups.filter(([count])=>count>0).map(([count,label])=>`${count} ${label}`);
  return `Party of ${present.length>1?`${present.slice(0,-1).join(', ')} and ${present.at(-1)}`:present[0]||'0 passengers'}`;
}

function googleMapsUrl(value:string){
  const url=new URL(value);
  const host=url.hostname.toLowerCase();
  if(!(host==='maps.app.goo.gl'||host==='maps.google.com'||host.endsWith('.maps.google.com')||/^maps[.]google[.][a-z.]+$/.test(host)||host==='www.google.com'||/^www[.]google[.][a-z.]+$/.test(host)))throw new Error('A valid Google Maps directions link is required');
  return url.toString();
}

export function buildTomorrowJourneyEmail(input:TomorrowJourneyEmailInput):{subject:string;text:string;html:string}{
  const wet = input.wetDestination
    ? `\n\n${input.destinationName} is a wet arrival destination, meaning you and your party will get wet. Please make sure you have appropriate clothes and a towel with this in mind.`
    : '';
  const party=passengerSummary(input);
  const directionsUrl=googleMapsUrl(input.pickupDirectionsUrl);
  const value=(text:string)=>`<strong>${escapeHtml(text)}</strong>`;
  const heading='font-size:19px;line-height:1.3;margin:28px 0 12px;color:#173042';
  const cell='padding:10px;border:1px solid #dce6ec;text-align:left;vertical-align:top';
  const subject=`Reminder of Itinerary for ${input.pickupName} to ${input.destinationName} tomorrow`;
  const wetHtml=input.wetDestination?`<p>${value(input.destinationName)} is a wet arrival destination, meaning you and your party will get wet. Please make sure you have appropriate clothes and a towel with this in mind.</p>`:'';
  const html=`<!doctype html><html><body style="margin:0;background:#f4f7f9;font-family:Arial,sans-serif;color:#173042"><table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td align="center" style="padding:28px 12px"><table role="presentation" width="100%" style="max-width:640px;background:#ffffff;border-radius:14px;overflow:hidden"><tr><td style="padding:24px 30px;background:#0877c9;color:#fff"><div style="font-size:24px;font-weight:700">Pace Shuttles</div><div style="margin-top:5px;font-size:14px">Seamless journeys. One booking.</div></td></tr><tr><td style="padding:30px;font-size:15px;line-height:1.65"><h1 style="font-size:24px;margin:0 0 22px">${escapeHtml(subject)}</h1><p>Hi ${escapeHtml(input.firstName)}</p><p>Your Pace Shuttles return journey in ${value(input.countryName)} between ${value(input.pickupName)} and ${value(input.destinationName)} is almost upon us.</p><p>Your ${value(input.vehicleType)} and captain have now been assigned to your trip.</p><h2 style="${heading}">Vehicle and captain</h2><p>${value(input.vehicleType)}: ${value(input.vehicleName)}<br/>Captain: ${value(input.captainFullName)}</p><h2 style="${heading}">Itinerary</h2><p>${value(party)}</p><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="border-collapse:collapse;margin:8px 0 18px"><tr><th style="${cell}">Journey</th><th style="${cell}">Route</th><th style="${cell}">Pick-up time</th><th style="${cell}">Please arrive by</th></tr><tr><td style="${cell}">${value('Journey 1')}</td><td style="${cell}">${value(`${input.pickupName} to ${input.destinationName}`)}</td><td style="${cell}">${value(input.outboundPickupTimeLabel)}</td><td style="${cell}">${value(input.outboundArrivalByTimeLabel)}</td></tr><tr><td style="${cell}">${value('Journey 2')}</td><td style="${cell}">${value(`${input.destinationName} to ${input.pickupName}`)}</td><td style="${cell}">${value(input.returnPickupTimeLabel)}</td><td style="${cell}">${value(input.returnArrivalByTimeLabel)}</td></tr></table><h2 style="${heading}">Arrival at ${value(input.pickupName)}</h2><p>${value(input.pickupArrivalNotes)}</p><p>Please arrive at ${value(input.pickupName)} by ${value(input.outboundArrivalByTimeLabel)}.</p><p>Directions are available at the following link:<br/><a href="${escapeHtml(directionsUrl)}" style="color:#0877c9;font-weight:700">📍 Directions to ${escapeHtml(input.pickupName)}</a></p><p>If you have trouble locating the ${value(input.vehicleType)}, please contact Captain ${value(input.captainSurname)} directly using the instructions below.</p>${wetHtml}<h2 style="${heading}">Contact Us</h2><p>On the day of the journey, you can contact Captain ${value(input.captainSurname)} if necessary using ${value('My Journeys > Help & Support > Contact the Captain')} in the Pace Shuttles portal.</p><p>We hope you have a great return trip to ${value(input.destinationName)} with Captain ${value(input.captainSurname)} onboard ${value(input.vehicleName)}.</p><p>Bon voyage!</p><p>The Pace Shuttles Team</p></td></tr><tr><td style="padding:20px 30px;border-top:1px solid #e5edf2;font-size:12px;color:#647681">Pace Shuttles · <a href="https://www.paceshuttles.com/customer" style="color:#0877c9">My Journeys</a> · hello@paceshuttles.com</td></tr></table></td></tr></table></body></html>`;
  return {
    subject,
    text: `Hi ${input.firstName}\n\nYour Pace Shuttles return journey in ${input.countryName} between ${input.pickupName} and ${input.destinationName} is almost upon us.\n\nYour ${input.vehicleType} and captain have now been assigned to your trip.\n\nVehicle and captain\n\n${input.vehicleType}: ${input.vehicleName}\n\nCaptain: ${input.captainFullName}\n\nItinerary\n\n${party}\n\nJourney 1: ${input.pickupName} to ${input.destinationName}\n\nPick up time: ${input.outboundPickupTimeLabel}\n\nPlease be at the ${input.vehicleType} by ${input.outboundArrivalByTimeLabel}\n\nJourney 2: ${input.destinationName} to ${input.pickupName}\n\nPick up time: ${input.returnPickupTimeLabel}\n\nPlease be at the ${input.vehicleType} by ${input.returnArrivalByTimeLabel}\n\nArrival at ${input.pickupName}\n\n${input.pickupArrivalNotes}\n\nPlease arrive at ${input.pickupName} by ${input.outboundArrivalByTimeLabel}.\n\nDirections are available at the following link:\n${directionsUrl}\n\nIf you have trouble locating the ${input.vehicleType}, please contact Captain ${input.captainSurname} directly using the instructions below.${wet}\n\nContact Us\n\nOn the day of the journey, you can contact Captain ${input.captainSurname} if necessary using My Journeys > Help & Support > Contact the Captain in the Pace Shuttles portal.\n\nWe hope you have a great return trip to ${input.destinationName} with Captain ${input.captainSurname} onboard ${input.vehicleName}.\n\nBon voyage!\n\nThe Pace Shuttles Team`,
    html
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
