import { describe, expect, it } from 'vitest';
import {
  buildCountryPayload,
  buildDestinationPayload,
  buildGeographyImagePath,
  buildPickupPayload,
  normalizeGoogleMapsUrl,
} from './admin-geography';

describe('admin geography contracts', () => {
  it('keeps country hierarchy and customer-facing media fields', () => {
    expect(buildCountryPayload({
      name: ' Antigua & Barbuda ', code: ' atg ', description: ' Island transfers ',
      picture_url: ' https://img.example/antigua.jpg ', timezone: ' America/Antigua ',
      is_large: false, region_label: 'Parish', locality_label: 'Town', active: true,
    })).toEqual({
      p_name: 'Antigua & Barbuda', p_code: 'ATG', p_description: 'Island transfers',
      p_picture_url: 'https://img.example/antigua.jpg', p_timezone: 'America/Antigua',
      p_is_large: false, p_region_label: 'Parish', p_locality_label: 'Town', p_active: true,
    });
  });

  it('builds the V1 pickup field set plus hierarchy, coordinates and directions', () => {
    const payload = buildPickupPayload({
      country_id: 'country-1', name: ' Jolly Harbour Marina ', address1: ' Dock A ', address2: '',
      town: 'Jolly Harbour', region: 'Saint Mary', postal_code: '', description: 'Main marina',
      picture_url: 'https://img.example/pickup.jpg', transport_type_id: 'boat',
      transport_type_place_id: 'marina', arrival_notes: 'Meet by the fuel dock',
      directions_url: 'https://maps.app.goo.gl/abc123', region_id: null, locality_id: null,
      latitude: '17.066', longitude: '-61.887', active: true,
    });
    expect(payload).toMatchObject({
      p_country_id: 'country-1', p_name: 'Jolly Harbour Marina', p_address1: 'Dock A',
      p_address2: null, p_transport_type_id: 'boat', p_transport_type_place_id: 'marina',
      p_arrival_notes: 'Meet by the fuel dock', p_directions_url: 'https://maps.app.goo.gl/abc123',
      p_latitude: 17.066, p_longitude: -61.887, p_active: true,
    });
    expect(payload).not.toHaveProperty('p_wet_or_dry');
  });

  it('builds destination-only arrival, contact, season and gift fields', () => {
    const payload = buildDestinationPayload({
      country_id: 'country-1', name: ' Loose Cannon ', address1: 'Dock', address2: '', town: 'English Harbour',
      region: '', postal_code: '', phone: '+1 268 555 0100', picture_url: 'https://img.example/destination.jpg',
      description: 'Beach club', season_from: '2026-11-01', season_to: '2027-05-31',
      destination_type: 'Beach Club', wet_or_dry: 'wet', url: 'https://example.com', gift: 'Welcome drink',
      arrival_notes: 'Use the tender dock', email: ' hello@example.com ',
      directions_url: 'https://www.google.com/maps/place/Loose+Cannon', region_id: null, locality_id: null,
      latitude: '', longitude: '', active: true,
    });
    expect(payload).toMatchObject({
      p_destination_type: 'Beach Club', p_wet_or_dry: 'wet', p_phone: '+1 268 555 0100',
      p_url: 'https://example.com', p_gift: 'Welcome drink', p_email: 'hello@example.com',
      p_season_from: '2026-11-01', p_season_to: '2027-05-31',
      p_directions_url: 'https://www.google.com/maps/place/Loose+Cannon',
    });
    expect(payload).not.toHaveProperty('p_transport_type_id');
  });

  it('accepts Google Maps URLs and rejects unrelated or insecure URLs', () => {
    expect(normalizeGoogleMapsUrl(' https://maps.google.com/?q=17,-61 ')).toBe('https://maps.google.com/?q=17,-61');
    expect(normalizeGoogleMapsUrl('https://maps.app.goo.gl/abc')).toBe('https://maps.app.goo.gl/abc');
    expect(() => normalizeGoogleMapsUrl('https://example.com/location')).toThrow('Google Maps');
    expect(() => normalizeGoogleMapsUrl('http://maps.google.com/?q=17,-61')).toThrow('https');
  });

  it('creates collision-resistant paths in the existing images folders', () => {
    expect(buildGeographyImagePath('pickup', 'Jolly Harbour Marina', 'Photo.JPG', 1720000000000))
      .toBe('pickup-points/jolly-harbour-marina-1720000000000.jpg');
    expect(buildGeographyImagePath('destination', 'Nobu Barbuda', 'hero.webp', 1720000000000))
      .toBe('destinations/nobu-barbuda-1720000000000.webp');
    expect(buildGeographyImagePath('country', 'Antigua & Barbuda', 'hero.png', 1720000000000))
      .toBe('countries/antigua-and-barbuda-1720000000000.png');
  });
});
