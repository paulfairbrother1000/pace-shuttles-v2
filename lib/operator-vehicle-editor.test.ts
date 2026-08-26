import {describe,expect,it} from 'vitest';
import {blankVehicleDraft,newRouteOffer,scopeVehicleEditorData,toVehicleSavePayload,validateVehicleDraft,vehicleToDraft} from './operator-vehicle-editor';

describe('operator vehicle editor draft',()=>{
 it('creates a blank vehicle without commercial defaults',()=>{
  expect(blankVehicleDraft()).toMatchObject({vehicleId:null,vehicleTypeId:'',preferredCaptainId:'',routeOffers:[]});
 });

 it('converts stored cents, basis points and ratios to editable values',()=>{
  const draft=vehicleToDraft({vehicle_id:'v1',operator_id:'o1',vehicle_type_id:'boat',name:'Sea Sea Rider',capacity_seats:10,active:true},[
   {offer_id:'of1',vehicle_id:'v1',route_id:'r1',route_name:'Jolly → Nobu',active:true,min_seats:4,max_seats:10,min_revenue_cents:140000,min_value_threshold_ratio:.8,below_minimum_operation_mode:'custom_threshold',post_min_discount_enabled:true,post_min_discount_bps:1500}
  ]);
  expect(draft.routeOffers[0]).toMatchObject({minRevenueUsd:'1400',discountPercent:'15',thresholdPercent:'80'});
 });

 it('validates capacity, duplicate routes and custom threshold',()=>{
  const draft=blankVehicleDraft(); Object.assign(draft,{name:'Boat',vehicleTypeId:'boat',capacitySeats:'8'});
  const route={operator_id:'o1',route_id:'r1',route_name:'Jolly → Nobu',vehicle_type_id:'boat',country_id:'ag'};
  draft.routeOffers=[newRouteOffer(route,'8'),newRouteOffer(route,'8')];
  Object.assign(draft.routeOffers[0],{minSeats:'4',maxSeats:'9',minRevenueUsd:'1200',belowMinimumMode:'custom_threshold',thresholdPercent:''});
  Object.assign(draft.routeOffers[1],{minSeats:'4',maxSeats:'8',minRevenueUsd:'1200'});
  expect(validateVehicleDraft(draft)).toMatchObject({
   'routeOffers.0.maxSeats':'Maximum seats cannot exceed vehicle capacity (8).',
   'routeOffers.0.thresholdPercent':'Threshold must be greater than 0% and no more than 100%.',
   'routeOffers.1.routeId':'This route is already attached.'
  });
 });

 it('submits explicit below-minimum and discount values',()=>{
  const draft=blankVehicleDraft(); Object.assign(draft,{name:'Boat',vehicleTypeId:'boat',capacitySeats:'10'});
  const offer=newRouteOffer({operator_id:'o1',route_id:'r1',route_name:'Route',vehicle_type_id:'boat',country_id:'ag'},'10');
  Object.assign(offer,{minSeats:'4',minRevenueUsd:'1400',discountEnabled:false,discountPercent:'25',belowMinimumMode:'never',thresholdPercent:'80'});
  draft.routeOffers=[offer];
  const payload=toVehicleSavePayload(draft) as any;
  expect(payload.route_offers[0]).toMatchObject({min_revenue_cents:140000,post_min_discount_bps:0,below_minimum_operation_mode:'never',min_value_threshold_ratio:null});
 });

 it('scopes every editor dataset to the operator selected by Site Admin',()=>{
  const scoped=scopeVehicleEditorData('o1',{
   vehicles:[{vehicle_id:'v1',operator_id:'o1'},{vehicle_id:'v2',operator_id:'o2'}],
   offers:[{offer_id:'a1',operator_id:'o1'},{offer_id:'a2',operator_id:'o2'}],
   captains:[{captain_id:'c1',operator_id:'o1'},{captain_id:'c2',operator_id:'o2'}],
   routes:[{route_id:'r1',operator_id:'o1'},{route_id:'r2',operator_id:'o2'}],
   vehicleTypes:[{vehicle_type_id:'t1',operator_id:'o1'},{vehicle_type_id:'t2',operator_id:'o2'}]
  } as any);
  expect(scoped.vehicles.map(x=>x.vehicle_id)).toEqual(['v1']);
  expect(scoped.offers.map(x=>x.offer_id)).toEqual(['a1']);
  expect(scoped.captains.map(x=>x.captain_id)).toEqual(['c1']);
  expect(scoped.routes.map(x=>x.route_id)).toEqual(['r1']);
  expect(scoped.vehicleTypes.map(x=>x.vehicle_type_id)).toEqual(['t1']);
 });
});
