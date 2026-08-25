export const visibleBookableJourneys = <T extends {quote_status?: string | null}>(rows:T[]) =>
  rows.filter(row => ['offer','check_price','loading_price'].includes(row.quote_status || ''));

export const defaultJourneyPartySizes = <T extends {departure_id:string}>(rows:T[]) =>
  Object.fromEntries(rows.map(row => [row.departure_id,1])) as Record<string,number>;

export const setJourneyPartySize = (current:Record<string,number>,departureId:string,partySize:number) => ({
  ...current,
  [departureId]: partySize,
});
