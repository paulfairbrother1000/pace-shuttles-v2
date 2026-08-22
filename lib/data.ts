'use client';
import { getSupabaseBrowserClient } from './supabase';
import { journeys as mockJourneys, operators as mockOperators } from './mock';

export async function loadAdminJourneys(){
  const supabase=getSupabaseBrowserClient();
  if(!supabase) return mockJourneys;
  const {data,error}=await supabase.from('api_admin_live_operations').select('*').order('scheduled_departure_ts',{ascending:true}).limit(100);
  if(error || !data?.length) return mockJourneys;
  return data;
}

export async function loadOperatorJourneys(){
  const supabase=getSupabaseBrowserClient();
  if(!supabase) return mockJourneys;
  const {data,error}=await supabase.from('api_operator_journeys').select('*').order('scheduled_departure_ts',{ascending:true}).limit(100);
  if(error || !data?.length) return mockJourneys;
  return data;
}

export async function loadOperatorLiabilities(){
  const supabase=getSupabaseBrowserClient();
  if(!supabase) return [];
  const {data,error}=await supabase.from('api_operator_liabilities').select('*').order('created_at',{ascending:false});
  return error ? [] : (data ?? []);
}

export async function loadCustomerNotifications(){
  const supabase=getSupabaseBrowserClient();
  if(!supabase) return [];
  const {data,error}=await supabase.from('api_customer_notifications').select('*').order('created_at',{ascending:false});
  return error ? [] : (data ?? []);
}

export async function loadSupportInbox(){
  const supabase=getSupabaseBrowserClient();
  if(!supabase) return [];
  const {data,error}=await supabase.from('api_support_inbox').select('*').order('updated_at',{ascending:false});
  return error ? [] : (data ?? []);
}

export async function loadOperatorsFallback(){ return mockOperators; }
