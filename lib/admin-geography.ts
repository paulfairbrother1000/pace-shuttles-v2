export type GeographyKind='country'|'pickup'|'destination';
export type DestinationPublicationIssue={field:string;message:string};

const text=(value:unknown)=>String(value??'').trim()||null;
const number=(value:unknown)=>value===''||value==null?null:Number(value);

export function normalizeGoogleMapsUrl(value:unknown){
 const raw=text(value); if(!raw)return null;
 let url:URL; try{url=new URL(raw)}catch{throw new Error('Enter a valid Google Maps link')}
 if(url.protocol!=='https:')throw new Error('Google Maps links must use https');
 const host=url.hostname.toLowerCase();
 if(!(host==='maps.app.goo.gl'||host==='goo.gl'||host==='maps.google.com'||host.endsWith('.google.com')))
  throw new Error('Enter a Google Maps link');
 if(host.endsWith('.google.com')&&!url.pathname.toLowerCase().includes('/maps')&&host!=='maps.google.com')
  throw new Error('Enter a Google Maps link');
 return url.toString();
}

function slugify(value:string){return value.toLowerCase().trim().replace(/&/g,' and ').replace(/['"]/g,'').replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'')||'image'}
export function buildGeographyImagePath(kind:GeographyKind,name:string,fileName:string,now=Date.now()){
 const folder=kind==='pickup'?'pickup-points':kind==='destination'?'destinations':'countries';
 const ext=(fileName.match(/\.([a-z0-9]+)$/i)?.[1]||'jpg').toLowerCase();
 return `${folder}/${slugify(name)}-${now}.${ext}`;
}

export function buildCountryPayload(form:any){return{
 p_name:text(form.name),p_code:text(form.code)?.toUpperCase(),p_description:text(form.description),
 p_picture_url:text(form.picture_url),p_timezone:text(form.timezone),p_is_large:!!form.is_large,
 p_region_label:text(form.region_label)||'Region',p_locality_label:text(form.locality_label)||'Town / City',p_active:form.active!==false,
}}

export function buildPickupPayload(form:any){return{
 p_country_id:text(form.country_id),p_name:text(form.name),p_address1:text(form.address1),p_address2:text(form.address2),
 p_town:text(form.town),p_region:text(form.region),p_postal_code:text(form.postal_code),p_picture_url:text(form.picture_url),
 p_description:text(form.description),p_transport_type_id:text(form.transport_type_id),
 p_transport_type_place_id:text(form.transport_type_place_id),p_arrival_notes:text(form.arrival_notes),
 p_directions_url:normalizeGoogleMapsUrl(form.directions_url),p_region_id:text(form.region_id),p_locality_id:text(form.locality_id),
 p_latitude:number(form.latitude),p_longitude:number(form.longitude),p_active:form.active!==false,
}}

export function buildDestinationPayload(form:any){return{
 p_country_id:text(form.country_id),p_name:text(form.name),p_address1:text(form.address1),p_address2:text(form.address2),
 p_town:text(form.town),p_region:text(form.region),p_postal_code:text(form.postal_code),p_phone:text(form.phone),
 p_picture_url:text(form.picture_url),p_description:text(form.description),p_season_from:text(form.season_from),p_season_to:text(form.season_to),
 p_destination_type:text(form.destination_type),p_wet_or_dry:text(form.wet_or_dry),p_url:text(form.url),p_gift:text(form.gift),
 p_arrival_notes:text(form.arrival_notes),p_email:text(form.email),p_directions_url:normalizeGoogleMapsUrl(form.directions_url),
 p_region_id:text(form.region_id),p_locality_id:text(form.locality_id),p_latitude:number(form.latitude),p_longitude:number(form.longitude),
 p_active:form.active!==false,
}}

export function validateDestinationPublication(form:any,country:{is_large?:boolean}={}):DestinationPublicationIssue[]{
 const issues:DestinationPublicationIssue[]=[];
 const required=(field:string,value:unknown,message:string)=>{if(!text(value))issues.push({field,message})};
 required('country_id',form?.country_id,'Country is required');
 if(country.is_large){required('region_id',form?.region_id,'Region is required');required('locality_id',form?.locality_id,'Town or city is required')}
 required('name',form?.name,'Name is required');
 required('destination_type',form?.destination_type,'Destination type is required');
 required('description',form?.description,'Description is required');
 required('picture_url',form?.picture_url,'Picture is required');
 if(!text(form?.address1)&&!text(form?.town))issues.push({field:'address',message:'Address or town is required'});
 const latitude=number(form?.latitude);if(latitude===null||!Number.isFinite(latitude)||latitude< -90||latitude>90)issues.push({field:'latitude',message:'Latitude must be between -90 and 90'});
 const longitude=number(form?.longitude);if(longitude===null||!Number.isFinite(longitude)||longitude< -180||longitude>180)issues.push({field:'longitude',message:'Longitude must be between -180 and 180'});
 try{if(!normalizeGoogleMapsUrl(form?.directions_url))throw new Error()}catch{issues.push({field:'directions_url',message:'A valid Google Maps link is required'})}
 if(!['wet','dry'].includes(String(form?.wet_or_dry||'')))issues.push({field:'wet_or_dry',message:'Wet or dry arrival type is required'});
 required('arrival_notes',form?.arrival_notes,'Arrival instructions are required');
 if(!text(form?.email)&&!text(form?.phone))issues.push({field:'contact',message:'Contact email or telephone is required'});
 return issues;
}
