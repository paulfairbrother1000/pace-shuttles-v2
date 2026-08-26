export type BelowMinimumMode='never'|'route_default'|'custom_threshold';

export type VehicleEditorRow={
 vehicle_id:string; operator_id:string; vehicle_type_id:string; vehicle_type_name?:string;
 name:string; description?:string|null; picture_url?:string|null; capacity_seats:number;
 active:boolean; preferred_captain_id?:string|null; updated_at?:string;
};

export type RouteOfferRow={
 offer_id:string; operator_id:string; vehicle_id:string; route_id:string; route_name:string; preferred?:boolean;
 active:boolean; min_seats:number; max_seats:number; min_revenue_cents:number;
 min_value_threshold_ratio?:number|null; below_minimum_operation_mode?:BelowMinimumMode|null;
 post_min_discount_enabled:boolean; post_min_discount_bps:number;
};

export type CaptainOption={operator_id:string;captain_id:string;captain_name:string;vehicle_type_id:string};
export type RouteOption={operator_id:string;route_id:string;route_name:string;vehicle_type_id:string;country_id:string;locality_id?:string|null};
export type VehicleTypeOption={operator_id:string;vehicle_type_id:string;vehicle_type_name:string};

export function scopeVehicleEditorData<T extends Record<string,{operator_id:string}[]>>(operatorId:string,data:T):T{
 return Object.fromEntries(Object.entries(data).map(([name,rows])=>[name,rows.filter(row=>row.operator_id===operatorId)])) as T;
}

export type RouteOfferDraft={
 key:string; offerId:string|null; routeId:string; routeName:string; preferred:boolean; active:boolean;
 minSeats:string; maxSeats:string; minRevenueUsd:string; discountEnabled:boolean; discountPercent:string;
 belowMinimumMode:BelowMinimumMode; thresholdPercent:string; remove:boolean;
};

export type VehicleEditorDraft={
 vehicleId:string|null; operatorId:string|null; vehicleTypeId:string; name:string; description:string;
 pictureUrl:string; capacitySeats:string; active:boolean; preferredCaptainId:string;
 expectedUpdatedAt:string|null;
 routeOffers:RouteOfferDraft[];
};

const key=()=>`draft-${Math.random().toString(36).slice(2)}`;
const numberText=(value:number)=>Number.isFinite(value)?String(value):'';

export function blankVehicleDraft():VehicleEditorDraft{
 return {vehicleId:null,operatorId:null,vehicleTypeId:'',name:'',description:'',pictureUrl:'',capacitySeats:'',active:true,preferredCaptainId:'',expectedUpdatedAt:null,routeOffers:[]};
}

export function offerToDraft(offer:RouteOfferRow):RouteOfferDraft{
 const mode=offer.below_minimum_operation_mode||(offer.min_value_threshold_ratio==null?'route_default':'custom_threshold');
 return {key:offer.offer_id,offerId:offer.offer_id,routeId:offer.route_id,routeName:offer.route_name,preferred:!!offer.preferred,
  active:offer.active!==false,minSeats:numberText(Number(offer.min_seats)),maxSeats:numberText(Number(offer.max_seats)),
  minRevenueUsd:numberText(Number(offer.min_revenue_cents||0)/100),discountEnabled:!!offer.post_min_discount_enabled,
  discountPercent:numberText(Number(offer.post_min_discount_bps||0)/100),belowMinimumMode:mode,
  thresholdPercent:mode==='custom_threshold'?numberText(Number(offer.min_value_threshold_ratio||0)*100):'',remove:false};
}

export function vehicleToDraft(vehicle:VehicleEditorRow,offers:RouteOfferRow[]):VehicleEditorDraft{
 return {vehicleId:vehicle.vehicle_id,operatorId:vehicle.operator_id,vehicleTypeId:vehicle.vehicle_type_id,name:vehicle.name||'',
  description:vehicle.description||'',pictureUrl:vehicle.picture_url||'',capacitySeats:numberText(Number(vehicle.capacity_seats)),
  active:vehicle.active!==false,preferredCaptainId:vehicle.preferred_captain_id||'',
  expectedUpdatedAt:vehicle.updated_at||null,
  routeOffers:offers.filter(x=>x.vehicle_id===vehicle.vehicle_id).map(offerToDraft)};
}

export function newRouteOffer(route:RouteOption,capacitySeats:string):RouteOfferDraft{
 return {key:key(),offerId:null,routeId:route.route_id,routeName:route.route_name,preferred:false,active:true,minSeats:'',
  maxSeats:capacitySeats,minRevenueUsd:'',discountEnabled:false,discountPercent:'0',belowMinimumMode:'never',thresholdPercent:'',remove:false};
}

export function validateVehicleDraft(draft:VehicleEditorDraft):Record<string,string>{
 const errors:Record<string,string>={};
 const capacity=Number(draft.capacitySeats);
 if(!draft.name.trim())errors.name='Enter a vehicle name.';
 if(!draft.vehicleTypeId)errors.vehicleTypeId='Select a Transport Type.';
 if(!Number.isInteger(capacity)||capacity<1)errors.capacitySeats='Passenger capacity must be a whole number of at least 1.';
 const routes=new Set<string>();
 draft.routeOffers.filter(x=>!x.remove).forEach((offer,index)=>{
  const prefix=`routeOffers.${index}`;
  const min=Number(offer.minSeats),max=Number(offer.maxSeats),revenue=Number(offer.minRevenueUsd),discount=Number(offer.discountPercent),threshold=Number(offer.thresholdPercent);
  if(!offer.routeId)errors[`${prefix}.routeId`]='Select a route.';
  if(routes.has(offer.routeId))errors[`${prefix}.routeId`]='This route is already attached.'; else routes.add(offer.routeId);
  if(!Number.isInteger(min)||min<1)errors[`${prefix}.minSeats`]='Minimum seats must be at least 1.';
  if(!Number.isInteger(max)||max<min)errors[`${prefix}.maxSeats`]='Maximum seats must be at least the minimum.';
  else if(Number.isFinite(capacity)&&max>capacity)errors[`${prefix}.maxSeats`]=`Maximum seats cannot exceed vehicle capacity (${capacity}).`;
  if(!Number.isFinite(revenue)||revenue<0)errors[`${prefix}.minRevenueUsd`]='Enter a valid minimum journey revenue.';
  if(offer.discountEnabled&&(!offer.discountPercent.trim()||!Number.isFinite(discount)||discount<=0||discount>100))errors[`${prefix}.discountPercent`]='Discount must be greater than 0% and no more than 100%.';
  if(offer.belowMinimumMode==='custom_threshold'&&(!Number.isFinite(threshold)||threshold<=0||threshold>100))errors[`${prefix}.thresholdPercent`]='Threshold must be greater than 0% and no more than 100%.';
 });
 return errors;
}

export function toVehicleSavePayload(draft:VehicleEditorDraft):Record<string,unknown>{
 return {vehicle_id:draft.vehicleId,operator_id:draft.operatorId,expected_updated_at:draft.expectedUpdatedAt,vehicle_type_id:draft.vehicleTypeId,name:draft.name.trim(),description:draft.description.trim()||null,
  picture_url:draft.pictureUrl.trim()||null,capacity_seats:Number(draft.capacitySeats),active:draft.active,
  preferred_captain_id:draft.preferredCaptainId||null,route_offers:draft.routeOffers.map(offer=>({
   offer_id:offer.offerId,route_id:offer.routeId,preferred:offer.preferred,active:offer.active,remove:offer.remove,
   min_seats:Number(offer.minSeats),max_seats:Number(offer.maxSeats),min_revenue_cents:Math.round(Number(offer.minRevenueUsd)*100),
   post_min_discount_enabled:offer.discountEnabled,post_min_discount_bps:offer.discountEnabled?Math.round(Number(offer.discountPercent||0)*100):0,
   below_minimum_operation_mode:offer.belowMinimumMode,
   min_value_threshold_ratio:offer.belowMinimumMode==='custom_threshold'?Number(offer.thresholdPercent)/100:null
  }))};
}
