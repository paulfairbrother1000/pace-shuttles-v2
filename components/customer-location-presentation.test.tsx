// @vitest-environment jsdom
import React from 'react';
import {cleanup,fireEvent,render,screen} from '@testing-library/react';
import {afterEach,describe,expect,it,vi} from 'vitest';
import {LocationDetailsModal,LocationImageButton} from './customer-location-presentation';

afterEach(cleanup);

describe('customer location presentation',()=>{
  it('shows only the location name on a clickable journey image',()=>{
    const onOpen=vi.fn();
    render(<LocationImageButton location={{name:'Jolly Harbour',picture_url:'/jolly.jpg'}} onOpen={onOpen}/>);

    const button=screen.getByRole('button',{name:'View Jolly Harbour information'});
    expect(button.textContent).toBe('Jolly Harbour');
    expect(screen.queryByText(/details/i)).toBeNull();
    fireEvent.click(button);
    expect(onOpen).toHaveBeenCalledOnce();
  });

  it('keeps the photograph and presents a map with directions in the light details panel',()=>{
    render(<LocationDetailsModal location={{
      name:'Boom',kind:'Destination',picture_url:'/boom.jpg',description:'A beautiful waterside destination.',
      address1:'Gunpowder House',town:'English Harbour',latitude:17.014,longitude:-61.765,
      directions_url:'https://maps.google.com/maps/dir/?api=1&destination=Boom',
    }} onClose={()=>{}}/>);

    expect(screen.getByRole('dialog',{name:'Boom information'})).toBeTruthy();
    expect(screen.getByRole('img',{name:'Boom'})).toBeTruthy();
    const map=screen.getByTitle('Map of Boom');
    expect(map.getAttribute('src')).toBe('https://www.google.com/maps?q=17.014%2C-61.765&z=15&output=embed');
    expect(map.getAttribute('loading')).toBe('lazy');
    expect(screen.getByRole('link',{name:'Get directions'}).getAttribute('href')).toBe('https://maps.google.com/maps/dir/?api=1&destination=Boom');
    expect(screen.queryByText('Open in Google Maps')).toBeNull();
  });

  it('falls back to a named map when coordinates are unavailable',()=>{
    render(<LocationDetailsModal location={{name:'Legacy pickup',picture_url:'/legacy.jpg'}} onClose={()=>{}}/>);
    expect(screen.getByRole('img',{name:'Legacy pickup'})).toBeTruthy();
    expect(screen.getByTitle('Map of Legacy pickup')).toBeTruthy();
  });
});
