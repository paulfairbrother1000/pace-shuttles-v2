'use client';
import Image from 'next/image';
import Link from 'next/link';
import { useEffect, useMemo, useState } from 'react';
import { getSupabaseBrowserClient } from '@/lib/supabase';
import { publicStorageImageUrl } from '@/lib/data';
import { availableCatalogue, availableJourneyDates, defaultJourneyPartySizes, journeyBookingCardState, journeyCapacityMessages, journeyPricePromotion, journeySeatLimit, journeysMatchingSelection, journeysNeedingCapacityHydration, setJourneyPartySize, visibleBookableJourneys, visibleJourneyResults } from '@/lib/customer-booking-view';
import {LocationDetailsModal,LocationImageButton} from '@/components/customer-location-presentation';
const money = (c: number) =>
  new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
    maximumFractionDigits: 0,
  }).format((c || 0) / 100);
const fallback = '/pace-hero.jpg';
function Photo({ src, alt, className = '' }: { src?: string | null; alt: string; className?: string }) {
  return (
    <img
      src={publicStorageImageUrl(src) || fallback}
      alt={alt}
      className={className}
      onError={(e) => {
        const el = e.currentTarget;
        if (!el.src.endsWith(fallback)) el.src = fallback;
      }}
    />
  );
}
export default function CustomerBooking() {
  const s = getSupabaseBrowserClient();
  const [bookableDates, setBookableDates] = useState<string[]>([]);
  const dates = bookableDates;
  const [countries, setCountries] = useState<any[]>([]),
    [catalogDests, setCatalogDests] = useState<any[]>([]),
    [catalogPickups, setCatalogPickups] = useState<any[]>([]),
    [deps, setDeps] = useState<any[]>([]),
    [results, setResults] = useState<any[]>([]),
    [journeyPartySizes, setJourneyPartySizes] = useState<Record<string, number>>({}),
    [country, setCountry] = useState(''),
    [dest, setDest] = useState(''),
    [pickup, setPickup] = useState(''),
    [day, setDay] = useState(''),
    [vehicleType, setVehicleType] = useState(''),
    [loading, setLoading] = useState(true),
    [searching, setSearching] = useState(false),
    [pricingId, setPricingId] = useState(''),
    [msg, setMsg] = useState(''),
    [browseTab, setBrowseTab] = useState<'destination' | 'pickup' | 'date' | 'type'>('destination'),
    [locationInfo, setLocationInfo] = useState<any | null>(null),
    [calendarOpen, setCalendarOpen] = useState(false),
    [calendarMonth, setCalendarMonth] = useState(() => {
      const d = new Date();
      return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
    });
  const routeKey = [country, dest, pickup, vehicleType].join('|');
  const [datesRouteKey, setDatesRouteKey] = useState('');
  useEffect(() => {
    (async () => {
      if (!s) return;
      const [c, cd, cp, d] = await Promise.all([s.from('v2_public_countries').select('*').order('display_order'), s.from('v2_public_destinations').select('*').order('sort_order').order('name'), s.from('v2_public_pickups').select('*').order('sort_order').order('name'), s.from('v2_public_departures').select('*').order('scheduled_departure_ts')]);
      setCountries(c.data || []);
      setCatalogDests(cd.data || []);
      setCatalogPickups(cp.data || []);
      setDeps(d.data || []);
      setLoading(false);
    })();
  }, [s]);
  const catalogue = useMemo(() => availableCatalogue(countries, catalogDests, catalogPickups, deps), [countries, catalogDests, catalogPickups, deps]);
  const visibleCountries = catalogue.countries;
  const filtered = visibleJourneyResults(results, journeyPartySizes);
  const matchingJourneyDeps = useMemo(
    () =>
      journeysMatchingSelection(deps, {
        countryId: country,
        destinationId: dest,
        pickupId: pickup,
        vehicleTypeId: vehicleType,
      }),
    [deps, country, dest, pickup, vehicleType],
  );
  const dests = useMemo(() => catalogue.destinations.filter((x) => !country || x.country_id === country), [catalogue.destinations, country]);
  const pickups = useMemo(() => catalogue.pickups.filter((x) => (!country || x.country_id === country) && deps.some((d) => (!country || d.country_id === country) && (!dest || d.destination_id === dest) && d.pickup_id === x.id)), [catalogue.pickups, deps, country, dest]);
  const types = useMemo(() => {
    const m = new Map<string, any>();
    deps.filter((x) => (!country || x.country_id === country) && (!dest || x.destination_id === dest) && (!pickup || x.pickup_id === pickup)).forEach((x) => (x.vehicle_types || []).forEach((v: any) => m.set(v.id || v.name, v)));
    return Array.from(m.values());
  }, [deps, country, dest, pickup]);
  const countryDeps = matchingJourneyDeps.filter((row) => dates.includes(row.local_departure_date));
  const partyFor = (id: string) => journeyPartySizes[id] || 1;
  async function quoteJourney(id: string, partySize: number) {
    if (!s) return;
    setPricingId(id);
    const { data, error } = await s.rpc('v2_public_quote', {
      p_departure_id: id,
      p_party_size: partySize,
    });
    setPricingId('');
    if (error) {
      setMsg(error.message);
      return;
    }
    const q = data?.[0];
    if (q)
      setResults((rows) =>
        rows.map((x) =>
          x.departure_id === id
            ? {
                ...x,
                ...q,
                max_party_size: Number(q.max_party_size) > 0 ? q.max_party_size : x.max_party_size,
              }
            : x,
        ),
      );
  }
  async function changeJourneyParty(id: string, partySize: number) {
    setJourneyPartySizes((cur) => setJourneyPartySize(cur, id, partySize));
    await quoteJourney(id, partySize);
  }
  async function choose(id: string) {
    if (!s) return;
    setMsg('');
    setPricingId(id);
    const { data, error } = await s.rpc('v2_public_create_quote_intent', {
      p_departure_id: id,
      p_party_size: partyFor(id),
    });
    setPricingId('');
    if (error) {
      setMsg(error.message);
      return;
    }
    window.location.href = '/checkout?q=' + encodeURIComponent(data);
  }
  async function hydrateLivePrices(rows: any[]) {
    if (!s || !rows.length) return;
    const targets = journeysNeedingCapacityHydration(rows);
    if (!targets.length) return;
    setResults((cur) => cur.map((x) => (targets.some((t) => t.departure_id === x.departure_id) ? { ...x, quote_status: 'loading_price' } : x)));
    for (let i = 0; i < targets.length; i += 4) {
      const chunk = targets.slice(i, i + 4);
      await Promise.all(
        chunk.map(async (x) => {
          const { data, error } = await s.rpc('v2_public_quote', {
            p_departure_id: x.departure_id,
            p_party_size: 1,
          });
          const q = data?.[0];
          setResults((cur) =>
            cur.map((r) =>
              r.departure_id === x.departure_id
                ? error || !q
                  ? {
                      ...r,
                      quote_status: 'unavailable',
                      quote_error: error?.message || 'No live offer for this departure',
                    }
                  : { ...r, ...q }
                : r,
            ),
          );
        }),
      );
    }
  }
  async function searchJourneys() {
    if (!s) return;
    setSearching(true);
    setMsg('');
    const args = {
      p_country_id: country || null,
      p_destination_id: dest || null,
      p_pickup_id: pickup || null,
      p_local_date: day || null,
      p_party_size: 1,
      p_vehicle_type_id: vehicleType || null,
    };
    const { data, error } = await s.rpc('v2_public_search_journeys', args);
    setSearching(false);
    if (error) {
      setMsg(error.message);
      setResults([]);
      setJourneyPartySizes({});
    } else {
      const rows = data || [];
      if (!day) {
        setBookableDates((current) => {
          const next = availableJourneyDates(visibleBookableJourneys(rows), {});
          return current.join('|') === next.join('|') ? current : next;
        });
        setDatesRouteKey(routeKey);
      }
      setResults(rows);
      setJourneyPartySizes(defaultJourneyPartySizes(rows));
      void hydrateLivePrices(rows);
    }
  }
  useEffect(() => {
    if (vehicleType && !types.some((type) => (type.id || type.name) === vehicleType)) setVehicleType('');
  }, [vehicleType, types]);
  useEffect(() => {
    setDay('');
  }, [routeKey]);
  useEffect(() => {
    if (day && !dates.includes(day)) setDay('');
  }, [day, dates]);
  useEffect(() => {
    if (country && (!day || (datesRouteKey === routeKey && dates.includes(day)))) void searchJourneys();
  }, [country, dest, pickup, day, vehicleType, dates, datesRouteKey, routeKey]);
  function resetCountry() {
    setCountry('');
    setDest('');
    setPickup('');
    setDay('');
    setVehicleType('');
    setResults([]);
    setJourneyPartySizes({});
    setBrowseTab('destination');
  }
  function chooseDestination(id: string) {
    setDest(id);
    setPickup('');
    setVehicleType('');
    setResults([]);
  }
  function setMonthFromDate(value: string) {
    if (value) setCalendarMonth(value.slice(0, 7));
  }
  function selectCalendarDay(value: string, close = true) {
    setDay(value);
    setMonthFromDate(value);
    if (close) setCalendarOpen(false);
  }
  function Calendar({ discovery = false }: { discovery?: boolean }) {
    const [yy, mm] = calendarMonth.split('-').map(Number);
    const first = new Date(yy, mm - 1, 1),
      last = new Date(yy, mm, 0);
    const start = (first.getDay() + 6) % 7;
    const slots = Array.from({ length: start + last.getDate() }, (_, i) => (i < start ? null : i - start + 1));
    while (slots.length % 7) slots.push(null);
    const monthRows = countryDeps.filter((x) => String(x.local_departure_date || '').startsWith(calendarMonth));
    const byDay = new Map<number, any[]>();
    monthRows.forEach((x) => {
      const n = Number(String(x.local_departure_date).slice(8, 10));
      byDay.set(n, [...(byDay.get(n) || []), x]);
    });
    const change = (delta: number) => {
      const d = new Date(yy, mm - 1 + delta, 1);
      setCalendarMonth(`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`);
    };
    const pick = (n: number) => {
      const v = `${calendarMonth}-${String(n).padStart(2, '0')}`;
      selectCalendarDay(v, !discovery);
      if (discovery) setBrowseTab('destination');
    };
    return (
      <div className="ps-calendar-shell">
        <div className="ps-calendar-head">
          <button onClick={() => change(-1)} aria-label="Previous month">
            ‹
          </button>
          <strong>{first.toLocaleDateString([], { month: 'long', year: 'numeric' })}</strong>
          <button onClick={() => change(1)} aria-label="Next month">
            ›
          </button>
        </div>
        <div className="ps-calendar-desktop">
          <div className="ps-calendar-weekdays">
            {['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((x) => (
              <span key={x}>{x}</span>
            ))}
          </div>
          <div className="ps-calendar-grid">
            {slots.map((n, i) => {
              const hasJourneys = n != null && (byDay.get(n) || []).length > 0;
              return n == null ? (
                <div key={'e' + i} className="ps-calendar-cell empty" />
              ) : (
                <button key={n} disabled={!hasJourneys} className={`ps-calendar-cell${day === `${calendarMonth}-${String(n).padStart(2, '0')}` ? ' selected' : ''}${(byDay.get(n) || []).length ? ' has-journeys' : ''}`} onClick={() => hasJourneys && pick(n)}>
                  <span className="ps-calendar-dayno">{n}</span>
                  <div className="ps-calendar-routes">
                    {(byDay.get(n) || []).slice(0, 5).map((x: any, j: number) => (
                      <span key={x.departure_id || j}>{x.route_name}</span>
                    ))}
                    {(byDay.get(n) || []).length > 5 && <em>+{(byDay.get(n) || []).length - 5} more</em>}
                  </div>
                </button>
              );
            })}
          </div>
        </div>
        <div className="ps-calendar-mobile">
          {Array.from(byDay.entries())
            .sort((a, b) => a[0] - b[0])
            .map(([n, rows]) => (
              <button key={n} className={day === `${calendarMonth}-${String(n).padStart(2, '0')}` ? 'selected' : ''} onClick={() => pick(n)}>
                <b>
                  {new Date(yy, mm - 1, n).toLocaleDateString([], {
                    weekday: 'short',
                    day: 'numeric',
                    month: 'short',
                  })}
                </b>
                <span>
                  {rows.length} journey{rows.length === 1 ? '' : 's'}
                </span>
                <small>
                  {rows
                    .slice(0, 3)
                    .map((x: any) => x.route_name)
                    .join(' · ')}
                  {rows.length > 3 ? ` · +${rows.length - 3} more` : ''}
                </small>
              </button>
            ))}
          {!byDay.size && <div className="ps-calendar-nojourneys">No scheduled journeys this month.</div>}
        </div>
        <div className="ps-calendar-foot">
          {day ? (
            <>
              <span>Selected: {new Date(day + 'T12:00:00').toLocaleDateString('en-GB')}</span>
              <button onClick={() => setDay('')}>Clear date</button>
            </>
          ) : (
            <span>Select a day to filter journeys.</span>
          )}
        </div>
      </div>
    );
  }
  return (
    <main className="ps-public">
      <header className="ps-public-header">
        <Link href="/" className="ps-wordmark">
          <Image src="/paceshuttles-logo.jpeg" alt="Pace Shuttles" width={180} height={55} />
        </Link>
        <nav>
          <Link href="/">Home</Link>
          <Link href="/book" className="active">
            Book
          </Link>
          <Link href="/customer">My journeys</Link>
        </nav>
      </header>
      <section className="ps-intro">
        <div>
          <p className="eyebrow">Luxury Transfers, Reimagined.</p>
          <h1>
            With Pace Shuttles, the journey <em>is</em> the destination.
          </h1>
          <p>Discover a new way to move between exclusive islands and shores with semi private, shared charters that blend exclusivity with ease. Discover some of the finest beach clubs, restaurants and bars in style, where every journey feels like a vacation of its own.</p>
          <p>We connect travellers, operators and destinations through one intelligent platform that handles booking, payments, scheduling and customer care.</p>
          <a className="ps-primary" href="#journeys">
            Find a journey
          </a>
        </div>
        <div className="ps-hero">
          <Image src="/pace-hero.jpg" alt="Pace Shuttles luxury transfer" fill priority className="cover" />
        </div>
      </section>
      {!country && (
        <section className="ps-section ps-country-stage" id="journeys">
          <h2>Where would you like to travel?</h2>
          <p className="muted">Select a location to begin your journey.</p>
          <div className="ps-country-grid">
            {visibleCountries.map((c) => (
              <button
                className="ps-country-card"
                key={c.id}
                onClick={() => {
                  setCountry(c.id);
                  setDest('');
                  setPickup('');
                  setBrowseTab('destination');
                }}
              >
                <Photo src={c.picture_url || c.hero_image_url} alt={c.name} />
                <div className="ps-country-overlay">
                  <b>{c.name}</b>
                  <span>{c.description || c.blurb || 'Explore available journeys'}</span>
                </div>
              </button>
            ))}
          </div>
        </section>
      )}
      {country && !dest && (
        <section className="ps-section ps-discovery" id="journeys">
          <button className="ps-back-chip" onClick={resetCountry}>
            ← change country
          </button>
          <div className="ps-discovery-panel">
            <div className="ps-discovery-tabs">
              <button className={browseTab === 'date' ? 'active' : ''} onClick={() => setBrowseTab('date')}>
                Date
              </button>
              <button className={browseTab === 'destination' ? 'active' : ''} onClick={() => setBrowseTab('destination')}>
                Destination
              </button>
              <button className={browseTab === 'pickup' ? 'active' : ''} onClick={() => setBrowseTab('pickup')}>
                Pickup
              </button>
              <button className={browseTab === 'type' ? 'active' : ''} onClick={() => setBrowseTab('type')}>
                Type
              </button>
            </div>
            {browseTab === 'destination' && (
              <>
                <p className="ps-discovery-label">Choose a destination</p>
                <div className="ps-destination-grid">
                  {dests.map((d: any) => (
                    <button key={d.id} className="ps-destination-card" onClick={() => chooseDestination(d.id)}>
                      <Photo src={d.picture_url} alt={d.name} />
                      <div>
                        <b>{d.name}</b>
                        <p>{d.description || 'Discover this destination with Pace Shuttles.'}</p>
                      </div>
                    </button>
                  ))}
                </div>
              </>
            )}
            {browseTab === 'pickup' && (
              <>
                <p className="ps-discovery-label">Choose your pick-up point</p>
                <div className="ps-destination-grid">
                  {pickups.map((p: any) => (
                    <button
                      key={p.id}
                      className="ps-destination-card"
                      onClick={() => {
                        setPickup(p.id);
                        setBrowseTab('destination');
                      }}
                    >
                      <Photo src={p.picture_url} alt={p.name} />
                      <div>
                        <b>{p.name}</b>
                        <p>{p.description || 'Start your Pace Shuttles journey here.'}</p>
                      </div>
                    </button>
                  ))}
                </div>
              </>
            )}
            {browseTab === 'date' && (
              <>
                <p className="ps-discovery-label">Choose a date — all scheduled journeys in this country are shown below.</p>
                <Calendar discovery />
              </>
            )}
            {browseTab === 'type' && (
              <>
                <p className="ps-discovery-label">Choose how you want to travel</p>
                <div className="ps-type-grid">
                  {types.map((t: any) => (
                    <button key={t.id || t.name} className={`ps-type-card${vehicleType === t.id ? ' selected' : ''}`} onClick={() => setVehicleType(vehicleType === t.id ? '' : t.id)}>
                      <Photo src={t.picture_url} alt={t.name} />
                      <b>{t.name}</b>
                    </button>
                  ))}
                </div>
              </>
            )}
          </div>
        </section>
      )}
      {country && (
        <section className="ps-section" id="journeys">
          <div className="ps-planner-head">
            <div>
              {dest ? (
                <button
                  className="ps-back"
                  onClick={() => {
                    setDest('');
                    setPickup('');
                    setResults([]);
                  }}
                >
                  ← All destinations
                </button>
              ) : (
                <button className="ps-back" onClick={() => setBrowseTab('destination')}>
                  Browse destinations
                </button>
              )}
              <h2>Plan your journey</h2>
            </div>
          </div>
          <div className="ps-filters">
            <label>
              Destination
              <select
                value={dest}
                onChange={(e) => {
                  setDest(e.target.value);
                  setPickup('');
                }}
              >
                <option value="">All destinations</option>
                {dests.map((d: any) => (
                  <option value={d.id} key={d.id}>
                    {d.name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Pick-up
              <select value={pickup} onChange={(e) => setPickup(e.target.value)}>
                <option value="">All pick-up points</option>
                {pickups.map((p: any) => (
                  <option value={p.id} key={p.id}>
                    {p.name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Date
              <button
                type="button"
                className="ps-date-filter-button"
                onClick={() => {
                  if (day) setMonthFromDate(day);
                  setCalendarOpen(true);
                }}
              >
                {day ? new Date(day + 'T12:00:00').toLocaleDateString('en-GB') : 'Choose date'} <span>▣</span>
              </button>
            </label>
            <label>
              Type
              <select value={vehicleType} onChange={(e) => setVehicleType(e.target.value)}>
                <option value="">All types</option>
                {types.map((t: any) => (
                  <option key={t.id} value={t.id}>
                    {t.name}
                  </option>
                ))}
              </select>
            </label>
          </div>
          {calendarOpen && (
            <div className="ps-calendar-modal" role="dialog" aria-modal="true" onClick={() => setCalendarOpen(false)}>
              <div className="ps-calendar-dialog" onClick={(e) => e.stopPropagation()}>
                <button className="ps-calendar-close" onClick={() => setCalendarOpen(false)}>
                  ×
                </button>
                <h3>Choose a date</h3>
                <p>See everything running in {countries.find((c) => c.id === country)?.name || 'this country'}.</p>
                <Calendar />
              </div>
            </div>
          )}
          {dates.length > 0 && (
            <div className="ps-available-dates">
              <span>Next available dates</span>
              {dates.slice(0, 8).map((d: any) => (
                <button key={d} className={day === d ? 'active' : ''} onClick={() => setDay(d)}>
                  {new Date(d + 'T12:00:00').toLocaleDateString([], {
                    weekday: 'short',
                    day: 'numeric',
                    month: 'short',
                  })}
                </button>
              ))}
              {day && (
                <button className="clear" onClick={() => setDay('')}>
                  Show all dates
                </button>
              )}
            </div>
          )}
          {msg && <div className="ps-alert">{msg}</div>}
          {loading || searching ? (
            <div className="ps-empty">Checking live availability…</div>
          ) : filtered.length === 0 ? (
            <div className="ps-empty">No journeys match those choices yet. Try another available date or pick-up point.</div>
          ) : (
            <div className="ps-results">
              {filtered.map((x) => {
                const q = x,
                  party = partyFor(x.departure_id),
                  loadingPrice = q.quote_status === 'check_price' || q.quote_status === 'loading_price',
                  offered = q.quote_status === 'offer',
                  cardState = journeyBookingCardState(q, pricingId === x.departure_id),
                  soldOut = cardState.soldOut,
                  unavailable = cardState.partyUnavailable,
                  pricePromotion = journeyPricePromotion(q),
                  seatLimit = journeySeatLimit(q),
                  seatOptions = Array.from({ length: seatLimit }, (_, i) => i + 1),
                  pickupLocation = catalogPickups.find((p: any) => p.id === x.pickup_id) || {name:x.pickup_name,picture_url:x.pickup_picture_url,kind:'Pick-up point'},
                  destinationLocation = catalogDests.find((d: any) => d.id === x.destination_id) || {name:x.destination_name,picture_url:x.destination_picture_url,description:x.destination_description,kind:'Destination'};
                return (
                  <article className="ps-journey" key={x.departure_id}>
                    <div className="ps-route-images">
                      <LocationImageButton location={pickupLocation} onOpen={()=>setLocationInfo(pickupLocation)}/>
                      <LocationImageButton location={destinationLocation} onOpen={()=>setLocationInfo(destinationLocation)}/>
                    </div>
                    <div className="ps-journey-main">
                      <div>
                        <h3>
                          {x.pickup_name} → {x.destination_name}
                        </h3>
                        <p>
                          {new Date(x.scheduled_departure_ts).toLocaleString([], {
                            weekday: 'short',
                            day: 'numeric',
                            month: 'short',
                            hour: '2-digit',
                            minute: '2-digit',
                          })}
                          {x.approx_duration_mins ? ` · ${x.approx_duration_mins} mins` : ''}
                        </p>
                        <small>{(x.vehicle_types || []).map((v: any) => v.name).join(' · ')}</small>
                      </div>
                      <div className="ps-price">
                        <label>
                          Seats{' '}
                          <select aria-label={`Seats for ${x.pickup_name} to ${x.destination_name}`} value={soldOut ? 'sold_out' : party} disabled={cardState.selectorDisabled} onChange={(e) => void changeJourneyParty(x.departure_id, +e.target.value)}>
                            {soldOut ? (
                              <option value="sold_out">Sold out</option>
                            ) : party > seatLimit ? (
                              <option value={party} disabled>
                                {party}
                              </option>
                            ) : null}
                            {!soldOut&&seatOptions.map((n) => <option key={n}>{n}</option>)}
                          </select>
                        </label>
                        {soldOut ? (
                          <>
                            <span>Availability</span>
                            <strong>Sold out</strong>
                            <small>This popular journey is fully booked.</small>
                          </>
                        ) : offered ? (
                          <>
                            {pricePromotion && <b className="ps-price-promotion">{pricePromotion}</b>}
                            <span>Per seat incl. tax & fees</span>
                            <strong>{money(q.all_in_unit_price_cents)}</strong>
                            <small>
                              {party} seat{party === 1 ? '' : 's'} · {money(q.all_in_total_cents)} total
                            </small>
                          </>
                        ) : unavailable ? (
                          <>
                            <span>Party unavailable</span>
                            <strong>Only {seatLimit} seats remain together</strong>
                            <small>Choose a smaller party to continue with this journey.</small>
                          </>
                        ) : (
                          <>
                            <span>Live price</span>
                            <strong className="ps-price-loading">Checking…</strong>
                            <small>Calculating the best current price for your party.</small>
                          </>
                        )}
                        {!soldOut&&journeyCapacityMessages(q).map((message) => (
                          <small className="ps-capacity-warning" key={message}>
                            {message}
                          </small>
                        ))}
                      </div>
                      <div className="ps-actions">
                        {soldOut ? (
                          <button className="ps-primary" disabled>
                            Sold out
                          </button>
                        ) : offered ? (
                          <button className="ps-primary" disabled={cardState.actionDisabled} onClick={() => choose(x.departure_id)}>
                            {cardState.actionLabel}
                          </button>
                        ) : unavailable ? (
                          <button className="ps-primary" disabled>
                            Choose a smaller party
                          </button>
                        ) : (
                          <button className="ps-primary" disabled>
                            Checking price…
                          </button>
                        )}
                      </div>
                    </div>
                  </article>
                );
              })}
            </div>
          )}
        </section>
      )}
      {locationInfo&&<LocationDetailsModal location={locationInfo} onClose={()=>setLocationInfo(null)}/>}
      <section className="ps-footer-cta">
        <Link href="/partners" aria-label="Apply to partner with Pace Shuttles">
          <Image src="/partners-cta.jpg" alt="Partner with Pace Shuttles" width={2400} height={600} />
        </Link>
      </section>
      <footer className="ps-footer">Pace Shuttles · Shared premium journeys, intelligently connected.</footer>
    </main>
  );
}
