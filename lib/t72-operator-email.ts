export type T72OperatorVehicle={
 vehicleType:string;
 vehicleName:string;
 captainName:string;
};

export type T72OperatorEmailInput={
 journeyName:string;
 departureDate:string;
 departureTime:string;
 t24Date:string;
 t24Time:string;
 operatorPortalUrl:string;
 vehicles:T72OperatorVehicle[];
};

const required=(value:string,label:string)=>{
 const normalized=String(value||'').trim();
 if(!normalized)throw new Error(`${label} is required for the T-72 operator email`);
 return normalized;
};

export function buildT72OperatorEmail(input:T72OperatorEmailInput):{subject:string;text:string}{
 const journeyName=required(input.journeyName,'Journey');
 const departureDate=required(input.departureDate,'Departure date');
 const departureTime=required(input.departureTime,'Departure time');
 const t24Date=required(input.t24Date,'T-24 date');
 const t24Time=required(input.t24Time,'T-24 time');
 const operatorPortalUrl=required(input.operatorPortalUrl,'Operator Portal URL');
 if(!Array.isArray(input.vehicles)||input.vehicles.length===0)throw new Error('At least one vehicle is required for the T-72 operator email');
 const vehicles=input.vehicles.map(vehicle=>({
  vehicleType:required(vehicle.vehicleType,'Vehicle type'),
  vehicleName:required(vehicle.vehicleName,'Vehicle name'),
  captainName:required(vehicle.captainName,'Assigned captain')
 }));

 if(vehicles.length===1){
  const vehicle=vehicles[0];
  return {
   subject:`${vehicle.vehicleName} is under consideration for ${journeyName}`,
   text:`Your ${vehicle.vehicleType} ${vehicle.vehicleName} is under consideration for the following journey.

Date: ${departureDate}
Time: ${departureTime}
Journey: ${journeyName}
Assigned captain: ${vehicle.captainName}

Please let us know immediately on the Operator Portal if your resources are no longer available:
${operatorPortalUrl}

If your resources are still available, no action is required at this time. We shall confirm whether we require your vehicle on ${t24Date} at around ${t24Time}.

Thanks,
The Pace Shuttles Team`
  };
 }

 const vehicleLines=vehicles.map(vehicle=>`• ${vehicle.vehicleType} ${vehicle.vehicleName} — Assigned captain: ${vehicle.captainName}`).join('\n');
 return {
  subject:`${vehicles.length} vehicles are under consideration for ${journeyName}`,
  text:`The following vehicles are under consideration for this journey.

Date: ${departureDate}
Time: ${departureTime}
Journey: ${journeyName}

Vehicles:
${vehicleLines}

Please let us know immediately on the Operator Portal if any of these resources are no longer available:
${operatorPortalUrl}

If your resources are still available, no action is required at this time. We shall confirm which vehicles we require on ${t24Date} at around ${t24Time}.

Thanks,
The Pace Shuttles Team`
 };
}
