'use client';
import { getSupabaseBrowserClient } from './supabase';

export type DbRow = Record<string, any>;
async function select(table:string, order?:string, limit=500){
  const s=getSupabaseBrowserClient(); if(!s) return {data:[] as DbRow[],error:new Error('Supabase not configured')};
  let q=s.from(table).select('*').limit(limit); if(order) q=q.order(order,{ascending:true});
  const {data,error}=await q; return {data:(data??[]) as DbRow[],error};
}
export async function loadAdminJourneys(){return select('v2_api_admin_live_operations','scheduled_departure_ts',250)}
export async function loadOperatorJourneys(){return select('v2_api_operator_journeys','scheduled_departure_ts',250)}
export async function loadOperatorLiabilities(){return select('v2_api_operator_liabilities','created_at',250)}
export async function loadCustomerBookings(){return select('v2_api_customer_bookings','scheduled_departure_ts',250)}
export async function loadCustomerNotifications(){return select('v2_api_customer_notifications','created_at',250)}
export async function loadSupportInbox(){return select('v2_api_support_inbox','updated_at',250)}
export async function loadOperators(){return select('v2_operators','name',250)}
export async function loadSettlements(){return select('v2_settlements','created_at',250)}
export async function loadCountries(){return select('v2_countries','name',250)}
export async function loadRoutes(){return select('v2_routes','route_name',500)}
export async function loadDestinations(){return select('v2_destinations','name',500)}
export async function loadPickups(){return select('v2_pickup_points','name',500)}
export async function loadVehicles(){return select('v2_vehicles','name',500)}
export async function loadCaptains(){return select('v2_captains','first_name',500)}

export async function loadAdminLiveOperationsDetail(){return select('v2_admin_live_operations_detail','scheduled_departure_ts',500)}
export async function loadAdminJourneyBookings(){return select('v2_admin_journey_bookings','booked_at',1000)}
export async function loadAdminJourneyAllocations(){return select('v2_admin_journey_allocations','confirmed_at',500)}

export async function loadRoutePerformance(){return select('v2_admin_route_performance','route_name',500)}
export async function loadCountryPerformance(){return select('v2_admin_country_performance','country_name',250)}
export async function loadDestinationPerformance(){return select('v2_admin_destination_performance','destination_name',500)}
export async function loadOperatorPerformance(){return select('v2_admin_operator_performance','operator_name',500)}

export async function rpc(name:string,args:Record<string,any>={}){
  const s=getSupabaseBrowserClient(); if(!s) return {data:null,error:new Error('Supabase not configured')};
  return s.rpc(name,args);
}
export async function loadVehicleTypes(){return select('v2_vehicle_types','display_order',250)}
export async function loadVehicleRouteOffers(){return select('v2_vehicle_route_offers','created_at',1000)}
export async function loadVehicleUnavailability(){return select('v2_vehicle_availability_exceptions','start_ts',1000)}
export const adminAutoAssignCaptain=(allocationId:string)=>rpc('v2_admin_auto_assign_captain',{p_confirmed_allocation_id:allocationId});
export const adminAssignCaptain=(allocationId:string,captainId:string,reason:string)=>rpc('v2_admin_assign_captain',{p_confirmed_allocation_id:allocationId,p_captain_id:captainId,p_reason:reason});
export const adminRefreshConsiderations=(departureId:string)=>rpc('v2_admin_refresh_vehicle_considerations',{p_departure_id:departureId,p_engine_version:'admin-ui-v1'});
export const adminCancelBooking=(bookingId:string,refundCents:number,reason:string)=>rpc('v2_admin_cancel_booking_and_request_refund',{p_booking_id:bookingId,p_requested_refund_cents:refundCents,p_reason:reason});
export const adminRegisterOperatorCancellation=(allocationId:string,replacementCents:number,feeCents:number,reason:string)=>rpc('v2_admin_register_operator_cancellation',{p_confirmed_allocation_id:allocationId,p_replacement_cost_cents:replacementCents,p_cancellation_fee_cents:feeCents,p_reason:reason});
export const adminCreateVehicle=(a:any)=>rpc('v2_admin_create_vehicle',a);
export const adminCreateCaptain=(a:any)=>rpc('v2_admin_create_captain',a);
export const adminSetCaptainVehicleType=(captainId:string,vehicleTypeId:string,active=true)=>rpc('v2_admin_set_captain_vehicle_type',{p_captain_id:captainId,p_vehicle_type_id:vehicleTypeId,p_active:active});
export const adminCreateRouteOffer=(a:any)=>rpc('v2_admin_create_route_offer',a);
export const adminSetRouteOfferActive=(offerId:string,active:boolean)=>rpc('v2_admin_set_route_offer_active',{p_offer_id:offerId,p_active:active});
export const adminAddVehicleUnavailability=(a:any)=>rpc('v2_admin_add_vehicle_unavailability',a);
