'use client';
import { getSupabaseBrowserClient } from './supabase';

export type DbRow = Record<string, any>;
async function select(table:string, order?:string, limit=500){
  const s=getSupabaseBrowserClient(); if(!s) return {data:[] as DbRow[],error:new Error('Supabase not configured')};
  let q=s.from(table).select('*').limit(limit); if(order) q=q.order(order,{ascending:true});
  const {data,error}=await q; return {data:(data??[]) as DbRow[],error};
}
export async function loadAdminJourneys(){return select('v2_api_admin_live_operations','scheduled_departure_ts',250)}
export async function loadOperatorJourneys(){return select('v2_operator_my_dashboard','scheduled_departure_ts',250)}
export async function loadOperatorLiabilities(){return select('v2_api_operator_liabilities','created_at',250)}
export async function loadCustomerBookings(){return select('v2_customer_my_orders','scheduled_departure_ts',250)}
export async function loadCustomerNotifications(){return select('v2_customer_my_notifications','created_at',250)}
export const customerMarkNotificationRead=(notificationId:string)=>rpc('v2_customer_mark_notification_read',{p_notification_id:notificationId});
export const customerMarkAllNotificationsRead=()=>rpc('v2_customer_mark_all_notifications_read',{});
export async function loadSupportInbox(){return select('v2_api_support_inbox','updated_at',250)}
export async function loadOperators(){return select('v2_operators','name',250)}
export async function loadSettlements(){return select('v2_admin_finance_settlements','due_at',500)}
export async function loadLedgerSummary(){return select('v2_admin_ledger_summary','account_code',500)}
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
export async function loadCountryCommissions(){return select('v2_country_commissions','effective_from',500)}
export async function loadOperatorCommissionOverrides(){return select('v2_operator_commission_overrides','effective_from',500)}
export async function loadCancellationPolicies(){return select('v2_cancellation_policies','name',250)}
export const adminAutoAssignCaptain=(allocationId:string)=>rpc('v2_admin_auto_assign_captain',{p_confirmed_allocation_id:allocationId});
export const adminAssignCaptain=(allocationId:string,captainId:string,reason:string)=>rpc('v2_admin_assign_captain',{p_confirmed_allocation_id:allocationId,p_captain_id:captainId,p_reason:reason});
export const adminRefreshConsiderations=(departureId:string)=>rpc('v2_admin_refresh_vehicle_considerations',{p_departure_id:departureId,p_engine_version:'admin-ui-v1'});
export const adminCancelBooking=(bookingId:string,refundCents:number,reason:string)=>rpc('v2_admin_cancel_booking_and_request_refund',{p_booking_id:bookingId,p_requested_refund_cents:refundCents,p_reason:reason});
export const adminRegisterOperatorCancellation=(allocationId:string,replacementCents:number,feeCents:number,reason:string)=>rpc('v2_admin_register_operator_cancellation',{p_confirmed_allocation_id:allocationId,p_replacement_cost_cents:replacementCents,p_cancellation_fee_cents:feeCents,p_reason:reason});
export const adminCreateVehicle=(a:any)=>rpc('v2_admin_create_vehicle',a);
export const adminCreateCaptain=(a:any)=>rpc('v2_admin_create_captain',a);
export const adminSetCaptainVehicleType=(captainId:string,vehicleTypeId:string,active=true)=>rpc('v2_admin_set_captain_vehicle_type',{p_captain_id:captainId,p_vehicle_type_id:vehicleTypeId,p_active:active});
export const adminCreateRouteOffer=(a:{
 p_vehicle_id:string;p_service_id:string;p_min_seats:number;p_max_seats:number;p_min_revenue_cents:number;
 p_preferred:boolean;p_min_value_threshold_ratio:number|null;p_post_min_discount_enabled:boolean;p_post_min_discount_bps:number;
})=>rpc('v2_admin_create_route_offer',a);
export const adminSetRouteOfferActive=(offerId:string,active:boolean)=>rpc('v2_admin_set_route_offer_active',{p_offer_id:offerId,p_active:active});
export const adminAddVehicleUnavailability=(a:any)=>rpc('v2_admin_add_vehicle_unavailability',a);

export const adminCreateOperator=(a:any)=>rpc('v2_admin_create_operator',a);
export const adminUpdateOperator=(a:any)=>rpc('v2_admin_update_operator',a);
export const adminSetCountryCommission=(countryId:string,bps:number,note:string)=>rpc('v2_admin_set_country_commission',{p_country_id:countryId,p_commission_bps:bps,p_note:note});
export const adminSetOperatorCommissionOverride=(operatorId:string,bps:number,reason:string)=>rpc('v2_admin_set_operator_commission_override',{p_operator_id:operatorId,p_commission_bps:bps,p_reason:reason});
export const adminEndOperatorCommissionOverride=(operatorId:string)=>rpc('v2_admin_end_operator_commission_override',{p_operator_id:operatorId});

export async function loadRegions(){return select('v2_regions','name',500)}
export async function loadLocalities(){return select('v2_localities','name',500)}
export async function loadRouteVehicleTypes(){return select('v2_route_vehicle_types','route_name',1000)}
export async function loadOperatorVehicleTypes(){return select('v2_operator_vehicle_types','operator_name',1000)}
export const adminUpdateCountryHierarchy=(countryId:string,isLarge:boolean,regionLabel:string,localityLabel:string)=>rpc('v2_admin_update_country_hierarchy',{p_country_id:countryId,p_is_large:isLarge,p_region_label:regionLabel,p_locality_label:localityLabel});
export const adminCreateRegion=(a:any)=>rpc('v2_admin_create_region',a);
export const adminCreateLocality=(a:any)=>rpc('v2_admin_create_locality',a);
export const adminCreatePickup=(a:any)=>rpc('v2_admin_create_pickup',a);
export const adminCreateDestination=(a:any)=>rpc('v2_admin_create_destination',a);
export const adminCreateRoute=(a:any)=>rpc('v2_admin_create_route',a);
export const adminSetRouteActive=(routeId:string,active:boolean)=>rpc('v2_admin_set_route_active',{p_route_id:routeId,p_active:active});
export const adminSetRouteVehicleType=(routeId:string,vehicleTypeId:string,active:boolean)=>rpc('v2_admin_set_route_vehicle_type',{p_route_id:routeId,p_vehicle_type_id:vehicleTypeId,p_active:active});
export const adminSetOperatorVehicleType=(operatorId:string,vehicleTypeId:string,approved:boolean,note:string)=>rpc('v2_admin_set_operator_vehicle_type',{p_operator_id:operatorId,p_vehicle_type_id:vehicleTypeId,p_approved:approved,p_note:note});

export const adminUpdateRoute=(a:any)=>rpc('v2_admin_update_route',a);
export const adminUpdatePickup=(a:any)=>rpc('v2_admin_update_pickup',a);
export const adminUpdateDestination=(a:any)=>rpc('v2_admin_update_destination',a);

export const adminCreateSettlement=(allocationId:string,dueAt:string)=>rpc('v2_admin_create_settlement',{p_confirmed_allocation_id:allocationId,p_due_at:dueAt});
export const adminApplyOperatorLiabilities=(settlementId:string)=>rpc('v2_admin_apply_operator_liabilities',{p_settlement_id:settlementId});
export const adminApproveSettlement=(settlementId:string)=>rpc('v2_admin_approve_settlement',{p_settlement_id:settlementId});
export const adminMarkSettlementSent=(settlementId:string,externalReference:string)=>rpc('v2_admin_mark_settlement_sent',{p_settlement_id:settlementId,p_external_reference:externalReference});
export const adminReconcileSettlementPaid=(settlementId:string,externalReference:string)=>rpc('v2_admin_reconcile_settlement_paid',{p_settlement_id:settlementId,p_external_reference:externalReference});

export async function loadAdminVehicleConsiderations(){return select('v2_admin_vehicle_considerations','updated_at',1000)}
export async function loadAdminSchedulerRuns(){return select('v2_admin_scheduler_runs','started_at',1000)}
export async function loadAdminSupportMessages(){return select('v2_admin_support_messages','created_at',2000)}
export async function loadAdminVoyageLogs(){return select('v2_admin_voyage_logs','created_at',1000)}
export async function loadAdminNotifications(){return select('v2_admin_notifications','created_at',1000)}
export async function loadAdminProfiles(){return select('v2_admin_profiles','created_at',1000)}
export const adminClaimSupportTicket=(ticketId:string)=>rpc('v2_admin_claim_support_ticket',{p_ticket_id:ticketId});
export const adminResolveSupportTicket=(ticketId:string,note:string)=>rpc('v2_admin_resolve_support_ticket',{p_ticket_id:ticketId,p_resolution_note:note});
export const adminCloseSupportConversation=(conversationId:string)=>rpc('v2_admin_close_support_conversation',{p_conversation_id:conversationId});
export const adminQueueNotification=(a:any)=>rpc('v2_admin_queue_notification',a);
export const adminSetDepartureRisk=(departureId:string,atRisk:boolean,reason:string|null)=>rpc('v2_admin_set_departure_risk',{p_departure_id:departureId,p_at_risk:atRisk,p_reason:reason});
export const adminProcessDepartureT72=(departureId:string,force=false)=>rpc('v2_admin_process_departure_t72',{p_departure_id:departureId,p_force:force});
export const adminProcessDepartureT24=(departureId:string,force=false)=>rpc('v2_admin_process_departure_t24',{p_departure_id:departureId,p_force:force});
export const adminRefreshLiveConsiderations=(departureId:string)=>rpc('v2_admin_refresh_live_considerations',{p_departure_id:departureId});

export async function loadCaptainMyJourneys(){return select('v2_captain_my_journeys','scheduled_departure_ts',250)}
export const captainStartJourney=(assignmentId:string)=>rpc('v2_captain_start_journey',{p_captain_assignment_id:assignmentId});
export const captainCompleteJourney=(assignmentId:string,normal:boolean,notes:string,incident:boolean,summary:string)=>rpc('v2_captain_complete_journey',{p_captain_assignment_id:assignmentId,p_completed_normally:normal,p_captain_notes:notes,p_incident_flag:incident,p_incident_summary:summary});
export const adminReplySupportMessage=(conversationId:string,message:string)=>rpc('v2_admin_reply_support_message',{p_conversation_id:conversationId,p_message_text:message});
export const adminCancelPendingNotification=(notificationId:string)=>rpc('v2_admin_cancel_pending_notification',{p_notification_id:notificationId});

// Operator self-service / captain operational detail
export async function loadOperatorConsiderations(){return select('v2_operator_my_considerations','scheduled_departure_ts',500)}
export async function loadOperatorFleet(){return select('v2_operator_my_fleet','name',500)}
export async function loadOperatorRouteOffers(){return select('v2_operator_my_route_offers','route_name',1000)}
export async function loadOperatorVehicleEditor(){return rpc('v2_operator_load_vehicle_editor',{})}
export async function loadOperatorVehicleEditorCaptains(){return rpc('v2_operator_load_vehicle_editor_captains',{})}
export async function loadOperatorVehicleEditorTypes(){return rpc('v2_operator_load_vehicle_editor_types',{})}
export async function loadOperatorVehicleEditorRoutes(){return rpc('v2_operator_load_vehicle_editor_routes',{})}
export async function loadOperatorVehicleEditorOffers(){return rpc('v2_operator_load_vehicle_editor_offers',{})}
export const operatorSaveVehicle=(payload:Record<string,unknown>)=>rpc('v2_operator_save_vehicle',{p_vehicle:payload});
export async function loadOperatorUnavailability(){return select('v2_operator_my_unavailability','start_ts',1000)}
export async function loadOperatorQuality(){return select('v2_operator_my_quality','operator_name',100)}
export async function loadOperatorFairness(){return select('v2_operator_my_fairness','operator_name',500)}
export const operatorWithdrawConsideration=(id:string,reason:string)=>rpc('v2_operator_withdraw_consideration',{p_consideration_id:id,p_reason:reason});
export const operatorAddUnavailability=(vehicleId:string,start:string,end:string,reasonCode:string,reasonNote:string)=>rpc('v2_operator_add_unavailability',{p_vehicle_id:vehicleId,p_start_ts:start,p_end_ts:end,p_reason_code:reasonCode,p_reason_note:reasonNote});
export const operatorRemoveUnavailability=(id:string)=>rpc('v2_operator_remove_unavailability',{p_exception_id:id});
export const operatorSetRouteOfferActive=(id:string,active:boolean)=>rpc('v2_operator_set_route_offer_active',{p_offer_id:id,p_active:active});
export async function loadCaptainManifest(){return select('v2_captain_my_manifest','scheduled_departure_ts',2000)}
export async function loadCaptainMessages(){return select('v2_captain_my_messages','created_at',1000)}


// Customer feedback/support, captain messaging, operator commercial controls
export async function loadCustomerFeedback(){return select('v2_customer_my_feedback','created_at',250)}
export async function loadCustomerSupport(){return select('v2_customer_my_support','updated_at',250)}
export async function loadCustomerSupportMessages(){return select('v2_customer_my_support_messages','created_at',1000)}
export const customerSubmitFeedback=(bookingId:string,nps:number,rating:number,comment:string,attribution:string)=>rpc('v2_customer_submit_feedback',{p_booking_id:bookingId,p_nps:nps,p_operator_rating:rating,p_comment:comment,p_attribution:attribution});
export const customerOpenSupport=(bookingId:string,message:string,category:string)=>rpc('v2_customer_open_support',{p_booking_id:bookingId,p_message:message,p_category:category});
export const customerReplySupport=(conversationId:string,message:string)=>rpc('v2_customer_reply_support',{p_conversation_id:conversationId,p_message:message});
export const captainSendJourneyMessage=(allocationId:string,message:string,category:string)=>rpc('v2_captain_send_journey_message',{p_confirmed_allocation_id:allocationId,p_message:message,p_category:category});
export const operatorUpdateRouteOffer=(offerId:string,minSeats:number,maxSeats:number,minRevenueCents:number,preferred:boolean,threshold:number|null,discountEnabled:boolean,discountBps:number)=>rpc('v2_operator_update_route_offer',{p_offer_id:offerId,p_min_seats:minSeats,p_max_seats:maxSeats,p_min_revenue_cents:minRevenueCents,p_preferred:preferred,p_threshold:threshold,p_discount_enabled:discountEnabled,p_discount_bps:discountBps});

// Production finance / refund / quality operations
export async function loadAdminRefundOperations(){return select('v2_admin_refund_operations','requested_at',1000)}
export async function loadAdminStripeReconciliation(){return select('v2_admin_stripe_reconciliation','received_at',1000)}
export async function loadAdminQualityEvidence(){return select('v2_admin_quality_evidence','occurred_at',1000)}
export async function loadAdminCustomerFeedback(){return select('v2_admin_customer_feedback','created_at',1000)}
export const adminApproveRefund=(refundRequestId:string,approvedCents:number)=>rpc('v2_admin_approve_refund',{p_refund_request_id:refundRequestId,p_approved_refund_cents:approvedCents});
export const adminRecordRefundPaid=(refundRequestId:string,providerRef:string)=>rpc('v2_admin_record_refund_paid',{p_refund_request_id:refundRequestId,p_provider_refund_ref:providerRef});
export const adminReviewFeedback=(feedbackId:string,attribution:string)=>rpc('v2_admin_review_feedback',{p_feedback_id:feedbackId,p_attribution:attribution});
export const adminRefreshQuality=(operatorId:string)=>rpc('v2_admin_refresh_quality',{p_operator_id:operatorId});
export const customerCancelBooking=(bookingId:string,reason:string)=>rpc('v2_customer_cancel_booking',{p_booking_id:bookingId,p_reason:reason});
export const customerCancellationPreview=(bookingId:string)=>rpc('v2_customer_cancellation_preview',{p_booking_id:bookingId});
export async function loadCustomerRefunds(){return select('v2_customer_my_refunds','requested_at',250)}


// Revenue-gap rescue / T-24 customer rescue workflows
export async function loadAdminRevenueRescues(){return select('v2_admin_revenue_rescues','opened_at',1000)}
export async function loadAdminRevenueRescueContributions(){return select('v2_admin_revenue_rescue_contributions','created_at',2000)}
export async function loadCustomerRescueOffers(){return select('v2_customer_my_rescue_offers','closes_at',250)}
export const adminOpenRevenueRescue=(departureId:string,considerationId:string,closesAt:string)=>rpc('v2_admin_open_revenue_rescue',{p_departure_id:departureId,p_consideration_id:considerationId,p_closes_at:closesAt});
export const adminCancelRevenueRescue=(campaignId:string)=>rpc('v2_admin_cancel_revenue_rescue',{p_campaign_id:campaignId});
export const customerPledgeRescue=(campaignId:string,bookingId:string,amountCents:number)=>rpc('v2_customer_pledge_rescue',{p_campaign_id:campaignId,p_booking_id:bookingId,p_amount_cents:amountCents});
export const adminRecordRescueContributionPaid=(contributionId:string,providerReference:string)=>rpc('v2_admin_record_rescue_contribution_paid',{p_contribution_id:contributionId,p_provider_reference:providerReference});

// Service scheduling and access management
export async function loadAdminServices(){return select('v2_admin_services','name',1000)}
export async function loadAdminAccessUsers(){return select('v2_admin_access_users','email',1000)}
export const adminCreateService=(a:any)=>rpc('v2_admin_create_service',a);
export const adminUpdateService=(a:any)=>rpc('v2_admin_update_service',a);
export const adminGenerateDepartures=(from:string,to:string)=>rpc('v2_admin_generate_departures',{p_from:from,p_to:to});
export const adminSetPlatformUser=(email:string,role:string,displayName:string)=>rpc('v2_admin_set_platform_user',{p_email:email,p_platform_role:role,p_display_name:displayName});
export const adminLinkOperatorUser=(operatorId:string,email:string,role:string)=>rpc('v2_admin_link_operator_user',{p_operator_id:operatorId,p_email:email,p_role:role});
export const adminSetOperatorMembershipActive=(membershipId:string,active:boolean)=>rpc('v2_admin_set_operator_membership_active',{p_membership_id:membershipId,p_active:active});
export const adminLinkCaptainUser=(captainId:string,email:string)=>rpc('v2_admin_link_captain_user',{p_captain_id:captainId,p_email:email});
export const adminUnlinkCaptainUser=(captainId:string)=>rpc('v2_admin_unlink_captain_user',{p_captain_id:captainId});
