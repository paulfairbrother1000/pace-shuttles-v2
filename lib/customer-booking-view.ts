export const visibleBookableJourneys = <T extends {quote_status?: string | null}>(rows:T[]) =>
  rows.filter(row => ['offer','check_price','loading_price'].includes(row.quote_status || ''));
