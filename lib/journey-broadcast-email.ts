export type JourneyBroadcastCategory = 'late_running'|'pickup_change'|'weather'|'safety'|'operational';

type JourneyBroadcastEmailInput={
  pickupName:string;
  destinationName:string;
  captainName:string;
  category:JourneyBroadcastCategory;
  message:string;
};

const categoryLabel:Record<JourneyBroadcastCategory,string>={
  late_running:'Late running',
  pickup_change:'Pickup update',
  weather:'Weather / conditions',
  safety:'Safety update',
  operational:'Operational update'
};

export function buildJourneyBroadcastEmail(input:JourneyBroadcastEmailInput){
  const label=categoryLabel[input.category];
  if(!label)throw new Error('Invalid journey broadcast category');
  const route=`${input.pickupName} to ${input.destinationName}`;
  const subject=`Journey update: ${label}`;
  const text=`Journey update — ${label}\n\nCaptain ${input.captainName} has sent an update for your journey from ${route}.\n\n${input.message}\n\nView this update and reply privately in My Journeys: https://www.paceshuttles.com/customer\n\nThe Pace Shuttles Team`;
  return {subject,text};
}
