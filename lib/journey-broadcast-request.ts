export function requestIdForBroadcast(existingRequestId:string,createId:()=>string){
  return existingRequestId||createId();
}
