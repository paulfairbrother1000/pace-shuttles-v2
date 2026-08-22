'use client';
import { getSupabaseBrowserClient } from './supabase';

export type DbRow = Record<string, any>;
async function select(table:string, order?:string, limit=500){
  const s=getSupabaseBrowserClient(); if(!s) return {data:[] as DbRow[],error:new Error('Supabase not configured')};
  let q=s.from(table).select('*').limit(limit); if(order) q=q.order(order,{ascending:true});
  const {data,error}=await q; return {data:(data??[]) as DbRow[],error};
}
export async function loadAdminJourneys(){return select('api_admin_live_operations','scheduled_departure_ts',250)}
export async function loadOperatorJourneys(){return select('api_operator_journeys','scheduled_departure_ts',250)}
export async function loadOperatorLiabilities(){return select('api_operator_liabilities','created_at',250)}
export async function loadCustomerBookings(){return select('api_customer_bookings','scheduled_departure_ts',250)}
export async function loadCustomerNotifications(){return select('api_customer_notifications','created_at',250)}
export async function loadSupportInbox(){return select('api_support_inbox','updated_at',250)}
export async function loadOperators(){return select('operators','name',250)}
export async function loadSettlements(){return select('settlements','created_at',250)}
export async function loadCountries(){return select('countries','name',250)}
export async function loadRoutes(){return select('routes','route_name',500)}
export async function loadDestinations(){return select('destinations','name',500)}
export async function loadPickups(){return select('pickup_points','name',500)}
export async function loadVehicles(){return select('vehicles','name',500)}
export async function loadCaptains(){return select('captains','first_name',500)}
