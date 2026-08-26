'use client';

import {useEffect,useRef,useState} from 'react';
import {
 loadOperatorVehicleEditor,loadOperatorVehicleEditorCaptains,loadOperatorVehicleEditorTypes,
 loadOperatorVehicleEditorRoutes,loadOperatorVehicleEditorOffers,operatorSaveVehicle
} from '@/lib/data';
import {scopeVehicleEditorData} from '@/lib/operator-vehicle-editor';
import {OperatorVehicleEditor} from './operator-vehicle-editor';

type EditorData={vehicles:any[];offers:any[];captains:any[];routes:any[];vehicleTypes:any[]};
const empty:EditorData={vehicles:[],offers:[],captains:[],routes:[],vehicleTypes:[]};

export function AdminOperatorVehicleEditor({operatorId}:{operatorId:string}){
 const [data,setData]=useState<EditorData>(empty);
 const [busy,setBusy]=useState(false);
 const [message,setMessage]=useState('');
 const operatorIdRef=useRef(operatorId);
 operatorIdRef.current=operatorId;

 const reload=async(expectedOperatorId=operatorId)=>{
  if(operatorIdRef.current!==expectedOperatorId)return;
  setData(empty);
  const [vehicles,offers,captains,routes,vehicleTypes]=await Promise.all([
   loadOperatorVehicleEditor(),loadOperatorVehicleEditorOffers(),loadOperatorVehicleEditorCaptains(),
   loadOperatorVehicleEditorRoutes(),loadOperatorVehicleEditorTypes()
  ]);
  if(operatorIdRef.current!==expectedOperatorId)return;
  const error=[vehicles,offers,captains,routes,vehicleTypes].find(result=>result.error)?.error;
  if(error){setMessage(error.message||String(error));return;}
  setData(scopeVehicleEditorData(expectedOperatorId,{
   vehicles:vehicles.data||[],offers:offers.data||[],captains:captains.data||[],routes:routes.data||[],vehicleTypes:vehicleTypes.data||[]
  }));
 };

 useEffect(()=>{setBusy(false);setMessage('');void reload(operatorId)},[operatorId]);

 const save=async(payload:Record<string,unknown>)=>{
  const expectedOperatorId=operatorId;
  setBusy(true);setMessage('');
  const result=await operatorSaveVehicle({...payload,operator_id:expectedOperatorId});
  if(operatorIdRef.current!==expectedOperatorId)return false;
  setBusy(false);
  if(result.error){setMessage(result.error.message||String(result.error));return false;}
  setMessage('Vehicle saved');await reload(expectedOperatorId);return true;
 };

 return <>
  {message&&<p className={message==='Vehicle saved'?'action-success':'action-error'}>{message}</p>}
  <OperatorVehicleEditor key={operatorId} {...data} busy={busy} onSave={save}/>
 </>;
}
