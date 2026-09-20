import type {MetadataRoute} from 'next';

export default function manifest():MetadataRoute.Manifest{
  return {
    name:'Pace Shuttles',
    short_name:'Pace Shuttles',
    description:'Seamless journeys. One booking.',
    start_url:'/',
    display:'standalone',
    background_color:'#ffffff',
    theme_color:'#ffffff',
    icons:[
      {src:'/icons/pace-shuttles-192.png',sizes:'192x192',type:'image/png',purpose:'any'},
      {src:'/icons/pace-shuttles-192.png',sizes:'192x192',type:'image/png',purpose:'maskable'},
      {src:'/icons/pace-shuttles-512.png',sizes:'512x512',type:'image/png',purpose:'any'},
      {src:'/icons/pace-shuttles-512.png',sizes:'512x512',type:'image/png',purpose:'maskable'}
    ]
  };
}
