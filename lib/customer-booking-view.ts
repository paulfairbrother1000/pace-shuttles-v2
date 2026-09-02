export const availableCatalogue = <T extends {id:string},D extends {id:string},P extends {id:string}>(countries:T[],destinations:D[],pickups:P[],departures:any[]) => {
  const countryIds=new Set(departures.map(row=>row.country_id));
  const destinationIds=new Set(departures.map(row=>row.destination_id));
  const pickupIds=new Set(departures.map(row=>row.pickup_id));
  return {countries:countries.filter(row=>countryIds.has(row.id)),destinations:destinations.filter(row=>destinationIds.has(row.id)),pickups:pickups.filter(row=>pickupIds.has(row.id))};
};

export type JourneySelection = {
  countryId?: string;
  destinationId?: string;
  pickupId?: string;
  vehicleTypeId?: string;
};

export const journeysMatchingSelection = (departures:any[],selection:JourneySelection) => departures.filter(row =>
  (!selection.countryId || row.country_id === selection.countryId) &&
  (!selection.destinationId || row.destination_id === selection.destinationId) &&
  (!selection.pickupId || row.pickup_id === selection.pickupId) &&
  (!selection.vehicleTypeId || (row.vehicle_types || []).some((type:any) => (type.id || type.name) === selection.vehicleTypeId))
);

export const availableJourneyDates = (departures:any[],selection:JourneySelection) => Array.from(new Set(
  journeysMatchingSelection(departures,selection).map(row => row.local_departure_date).filter(Boolean)
)).sort() as string[];

export const visibleBookableJourneys = <T extends {quote_status?: string | null}>(rows:T[]) =>
  rows.filter(row => ['offer','check_price','loading_price','sold_out_for_party'].includes(row.quote_status || ''));

export const visibleJourneyResults = <T extends {departure_id:string;quote_status?:string|null}>(rows:T[],partySizes:Record<string,number>) =>
  rows.filter(row => ['offer','check_price','loading_price','sold_out_for_party'].includes(row.quote_status || ''));

export const journeysNeedingCapacityHydration = <T extends {quote_status?:unknown;remaining_seats_total?:unknown;max_party_size?:unknown}>(rows:T[]) =>
  rows.filter(row => row.quote_status==='check_price'||row.remaining_seats_total==null||row.max_party_size==null);

export const journeyBookingCardState = (
  journey:{quote_status?:unknown;remaining_seats_total?:unknown},
  pricing:boolean,
) => {
  const quoteStatus=String(journey.quote_status || '');
  const remaining=Math.max(0,Math.floor(Number(journey.remaining_seats_total || 0)));
  const soldOut=quoteStatus==='sold_out_for_party'&&remaining===0;
  const partyUnavailable=quoteStatus==='sold_out_for_party'&&!soldOut;
  return {
    soldOut,
    partyUnavailable,
    selectorDisabled:soldOut||pricing,
    actionDisabled:soldOut||partyUnavailable||pricing||quoteStatus!=='offer',
    actionLabel:soldOut?'Sold out':partyUnavailable?'Choose a smaller party':pricing?'Updating…':quoteStatus==='offer'?'Continue':'Checking price…',
  };
};

export const journeySeatLimit = (journey:{max_party_size?:unknown}) => {
  const liveLimit=Number(journey.max_party_size || 0);
  return liveLimit > 0 ? Math.min(12,Math.floor(liveLimit)) : 12;
};

export const journeyCapacityMessages = (journey:{remaining_seats_total?:unknown;max_party_size?:unknown}) => {
  const total=Math.max(0,Math.floor(Number(journey.remaining_seats_total || 0)));
  const party=Math.max(0,Math.floor(Number(journey.max_party_size || 0)));
  const messages:string[]=[];
  if(total>0&&total<=4)messages.push(`Only ${total} seat${total===1?'':'s'} remaining`);
  if(total>0&&total<=4&&total>party&&party>0)messages.push(`Maximum party size: ${party}`);
  return messages;
};

export const journeyPricePromotion = (journey:{quote_status?:unknown;discount_applied?:unknown}) =>
  journey.quote_status==='offer'&&journey.discount_applied===true?'REDUCED':null;

export const googleMapsEmbedUrl = (location:{latitude?:unknown;longitude?:unknown}) => {
  if(location.latitude==null||location.longitude==null||location.latitude===''||location.longitude==='')return null;
  const latitude=Number(location.latitude),longitude=Number(location.longitude);
  if(!Number.isFinite(latitude)||!Number.isFinite(longitude)||latitude < -90||latitude > 90||longitude < -180||longitude > 180)return null;
  const params=new URLSearchParams({q:`${latitude},${longitude}`,z:'15',output:'embed'});
  return `https://www.google.com/maps?${params.toString()}`;
};

export const defaultJourneyPartySizes = <T extends {departure_id:string}>(rows:T[]) =>
  Object.fromEntries(rows.map(row => [row.departure_id,1])) as Record<string,number>;

export const setJourneyPartySize = (current:Record<string,number>,departureId:string,partySize:number) => ({
  ...current,
  [departureId]: partySize,
});
