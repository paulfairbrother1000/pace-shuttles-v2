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
  rows.filter(row => ['offer','check_price','loading_price'].includes(row.quote_status || ''));

export const defaultJourneyPartySizes = <T extends {departure_id:string}>(rows:T[]) =>
  Object.fromEntries(rows.map(row => [row.departure_id,1])) as Record<string,number>;

export const setJourneyPartySize = (current:Record<string,number>,departureId:string,partySize:number) => ({
  ...current,
  [departureId]: partySize,
});
