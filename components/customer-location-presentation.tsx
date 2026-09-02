'use client';
import React from 'react';
import {publicStorageImageUrl} from '@/lib/data';
import {googleMapsEmbedUrl} from '@/lib/customer-booking-view';

const fallback='/pace-hero.jpg';

export type CustomerLocation={
  id?:string;name:string;kind?:string;picture_url?:string|null;description?:string|null;
  address1?:string|null;address2?:string|null;town?:string|null;region?:string|null;postal_code?:string|null;
  arrival_notes?:string|null;phone?:string|null;directions_url?:string|null;url?:string|null;
  latitude?:unknown;longitude?:unknown;
};

function LocationPhoto({location}:{location:CustomerLocation}){
  return <img src={publicStorageImageUrl(location.picture_url)||fallback} alt={location.name} onError={event=>{
    const image=event.currentTarget;
    if(!image.src.endsWith(fallback))image.src=fallback;
  }}/>;
}

export function LocationImageButton({location,onOpen}:{location:CustomerLocation;onOpen:()=>void}){
  return <button type="button" title={`View ${location.name} information`} aria-label={`View ${location.name} information`} onClick={onOpen}>
    <LocationPhoto location={location}/>
    <span>{location.name}</span>
  </button>;
}

export function LocationDetailsModal({location,onClose}:{location:CustomerLocation;onClose:()=>void}){
  const mapUrl=googleMapsEmbedUrl(location);
  const address=[location.address1,location.address2,location.town,location.region,location.postal_code].filter(Boolean).join(', ');
  const headingId='customer-location-heading';
  return <div className="ps-location-modal" onClick={onClose}>
    <div className="ps-location-dialog" role="dialog" aria-modal="true" aria-label={`${location.name} information`} onClick={event=>event.stopPropagation()}>
      <button className="ps-location-close" type="button" aria-label="Close location information" onClick={onClose}>×</button>
      <div className="ps-location-photo"><LocationPhoto location={location}/></div>
      <div className="ps-location-copy">
        <span className="ps-location-kicker">{location.kind||'Location'}</span>
        <h2 id={headingId}>{location.name}</h2>
        {location.description&&<p>{location.description}</p>}
        <dl>
          {address&&<><dt>Location</dt><dd>{address}</dd></>}
          {location.arrival_notes&&<><dt>Arrival information</dt><dd>{location.arrival_notes}</dd></>}
          {location.phone&&<><dt>Telephone</dt><dd>{location.phone}</dd></>}
        </dl>
        <div className="ps-location-links">
          {location.directions_url&&<a className="ps-primary" href={location.directions_url} target="_blank" rel="noreferrer">Get directions</a>}
          {location.url&&<a className="ps-secondary-link" href={location.url} target="_blank" rel="noreferrer">Visit website</a>}
        </div>
      </div>
      {mapUrl&&<div className="ps-location-map">
        <iframe src={mapUrl} title={`Map of ${location.name}`} loading="lazy" referrerPolicy="no-referrer-when-downgrade"/>
      </div>}
    </div>
  </div>;
}
