import {describe,expect,it} from 'vitest';
import {blankVehicleDraft,formatServiceSchedule,newRouteOffer,scopeVehicleEditorData,toVehicleSavePayload,validateVehicleDraft,vehicleToDraft} from './operator-vehicle-editor';

describe('operator vehicle editor draft',()=>{
 it('creates a blank vehicle without commercial defaults',()=>{
  expect(blankVehicleDraft()).toMatchObject({vehicleId:null,vehicleTypeId:'',preferredCaptainId:'',routeOffers:[]});
 });

 it('converts stored cents, basis points and ratios to editable values',()=>{
  const draft=vehicleToDraft({vehicle_id:'v1',operator_id:'o1',vehicle_type_id:'boat',name:'Sea Sea Rider',capacity_seats:10,active:true},[
   {offer_id:'of1',operator_id:'o1',vehicle_id:'v1',route_id:'r1',route_name:'Jolly → Nobu',service_id:'s1',active:true,min_seats:4,max_seats:10,min_revenue_cents:140000,min_value_threshold_ratio:.8,below_minimum_operation_mode:'custom_threshold',post_min_discount_enabled:true,post_min_discount_bps:1500,preferred_captain_id:'c2'}
  ]);
  expect(draft.routeOffers[0]).toMatchObject({preferredCaptainId:'c2',minRevenueUsd:'1400',discountPercent:'15',thresholdPercent:'80'});
 });

 it('formats service schedules using database weekday values and hour-minute times',()=>{
  expect(formatServiceSchedule([6],'10:00:00')).toBe('Saturday at 10:00');
  expect(formatServiceSchedule([2],'11:00:00')).toBe('Tuesday at 11:00');
  expect(formatServiceSchedule([1,3,7],'08:30:00')).toBe('Monday, Wednesday, Sunday at 08:30');
 });

 it('allows separate scheduled services for the same route but rejects a duplicate service',()=>{
  const draft=blankVehicleDraft(); Object.assign(draft,{name:'Boat',vehicleTypeId:'boat',capacitySeats:'8'});
  const saturday={operator_id:'o1',route_id:'r1',route_name:'Jolly → Nobu',service_id:'saturday',days_of_week:[6],departure_time:'10:00:00',timezone:'America/Antigua',vehicle_type_id:'boat',country_id:'ag'};
  const tuesday={operator_id:'o1',route_id:'r1',route_name:'Jolly → Nobu',service_id:'tuesday',days_of_week:[2],departure_time:'11:00:00',timezone:'America/Antigua',vehicle_type_id:'boat',country_id:'ag'};
  draft.routeOffers=[newRouteOffer(saturday,'8'),newRouteOffer(tuesday,'8'),newRouteOffer(saturday,'8')];
  for(const offer of draft.routeOffers)Object.assign(offer,{minSeats:'4',maxSeats:'8',minRevenueUsd:'1200'});
  expect(validateVehicleDraft(draft)).toMatchObject({'routeOffers.2.serviceId':'This service is already attached.'});
  expect(validateVehicleDraft(draft)['routeOffers.1.serviceId']).toBeUndefined();
 });

 it('validates capacity, duplicate services and custom threshold',()=>{
  const draft=blankVehicleDraft(); Object.assign(draft,{name:'Boat',vehicleTypeId:'boat',capacitySeats:'8'});
  const route={operator_id:'o1',route_id:'r1',route_name:'Jolly → Nobu',service_id:'s1',days_of_week:[6],departure_time:'10:00:00',timezone:'America/Antigua',vehicle_type_id:'boat',country_id:'ag'};
  draft.routeOffers=[newRouteOffer(route,'8'),newRouteOffer(route,'8')];
  Object.assign(draft.routeOffers[0],{minSeats:'4',maxSeats:'9',minRevenueUsd:'1200',belowMinimumMode:'custom_threshold',thresholdPercent:''});
  Object.assign(draft.routeOffers[1],{minSeats:'4',maxSeats:'8',minRevenueUsd:'1200'});
  expect(validateVehicleDraft(draft)).toMatchObject({
   'routeOffers.0.maxSeats':'Maximum seats cannot exceed vehicle capacity (8).',
   'routeOffers.0.thresholdPercent':'Threshold must be greater than 0% and no more than 100%.',
   'routeOffers.1.serviceId':'This service is already attached.'
  });
 });

 it('submits explicit below-minimum and discount values',()=>{
  const draft=blankVehicleDraft(); Object.assign(draft,{name:'Boat',vehicleTypeId:'boat',capacitySeats:'10'});
  const offer=newRouteOffer({operator_id:'o1',route_id:'r1',route_name:'Route',service_id:'s1',days_of_week:[6],departure_time:'10:00:00',timezone:'America/Antigua',vehicle_type_id:'boat',country_id:'ag'},'10');
  Object.assign(offer,{minSeats:'4',minRevenueUsd:'1400',discountEnabled:false,discountPercent:'25',belowMinimumMode:'never',thresholdPercent:'80'});
  draft.routeOffers=[offer];
  const payload=toVehicleSavePayload(draft) as any;
  expect(payload.route_offers[0]).toMatchObject({service_id:'s1',route_id:'r1',preferred_captain_id:null,min_revenue_cents:140000,post_min_discount_bps:0,below_minimum_operation_mode:'never',min_value_threshold_ratio:null});
 });

 it('scopes every editor dataset to the operator selected by Site Admin',()=>{
  const scoped=scopeVehicleEditorData('o1',{
   vehicles:[{vehicle_id:'v1',operator_id:'o1'},{vehicle_id:'v2',operator_id:'o2'}],
   offers:[{offer_id:'a1',operator_id:'o1'},{offer_id:'a2',operator_id:'o2'}],
   captains:[{captain_id:'c1',operator_id:'o1'},{captain_id:'c2',operator_id:'o2'}],
   routes:[{route_id:'r1',operator_id:'o1'},{route_id:'r2',operator_id:'o2'}],
   vehicleTypes:[{vehicle_type_id:'t1',operator_id:'o1'},{vehicle_type_id:'t2',operator_id:'o2'}]
  } as any);
  expect(scoped.vehicles.map((x:any)=>x.vehicle_id)).toEqual(['v1']);
  expect(scoped.offers.map((x:any)=>x.offer_id)).toEqual(['a1']);
  expect(scoped.captains.map((x:any)=>x.captain_id)).toEqual(['c1']);
  expect(scoped.routes.map((x:any)=>x.route_id)).toEqual(['r1']);
  expect(scoped.vehicleTypes.map((x:any)=>x.vehicle_type_id)).toEqual(['t1']);
 });
});
