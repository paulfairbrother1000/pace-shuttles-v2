'use client';
import {useEffect,useState} from 'react';
import {adminSaveVehicleType,adminUploadTransportTypeImage,loadVehicleTypes} from '@/lib/data';
import {Section,Status} from './ui';

const empty={code:'',name:'',description:'',picture_url:'',display_order:0,active:true};
export function AdminTransportTypes(){
 const [types,setTypes]=useState<any[]>([]),[editing,setEditing]=useState<any|null>(null),[form,setForm]=useState<any>(empty),[file,setFile]=useState<File|null>(null),[preview,setPreview]=useState(''),[busy,setBusy]=useState(false),[error,setError]=useState('');
 useEffect(()=>{loadVehicleTypes().then(r=>{setTypes(r.data);if(r.error)setError(r.error.message)})},[]);
 useEffect(()=>{if(!file){setPreview('');return}const url=URL.createObjectURL(file);setPreview(url);return()=>URL.revokeObjectURL(url)},[file]);
 const open=(item?:any)=>{setEditing(item||{});setForm({...empty,...item});setFile(null);setError('')};
 const close=()=>{if(!busy)setEditing(null)};
 const set=(name:string,value:any)=>setForm((x:any)=>({...x,[name]:value}));
 const save=async()=>{
  if(!String(form.name||'').trim())return setError('Transport type name is required');
  if(!String(form.code||'').trim())return setError('Transport type code is required');
  const order=Number(form.display_order);if(!Number.isInteger(order)||order<0)return setError('Display order must be a whole number of zero or more');
  setBusy(true);setError('');let picture_url=String(form.picture_url||'').trim()||null;
  if(file){const uploaded=await adminUploadTransportTypeImage(form.name,file);if(uploaded.error){setBusy(false);return setError(uploaded.error.message)}picture_url=uploaded.data}
  const result=await adminSaveVehicleType({p_vehicle_type_id:editing?.id||null,p_code:String(form.code).trim().toUpperCase().replace(/[^A-Z0-9]+/g,'_'),p_name:String(form.name).trim(),p_description:String(form.description||'').trim()||null,p_picture_url:picture_url,p_display_order:order,p_active:!!form.active});
  setBusy(false);if(result.error)return setError(result.error.message);window.location.reload();
 };
 return <><Section title="Transport types" action={<button className="btn" onClick={()=>open()}>+ Add transport type</button>}><p className="data-note">These types drive customer filter tiles, operator approvals, eligible vehicles and route compatibility.</p><div className="table-scroll"><table className="table transport-types-table"><thead><tr><th>Tile</th><th>Transport type</th><th>Order</th><th>Status</th><th></th></tr></thead><tbody>{types.map(t=><tr key={t.id}><td>{t.picture_url?<img className="transport-type-thumb" src={t.picture_url} alt=""/>:'—'}</td><td><b>{t.name}</b><br/><small>{t.code} · {t.description||'No description'}</small></td><td>{t.display_order}</td><td><Status value={t.active?'ACTIVE':'INACTIVE'}/></td><td><button className="btn secondary" onClick={()=>open(t)}>Edit</button></td></tr>)}{!types.length&&<tr><td className="empty-state" colSpan={5}>No transport types configured.</td></tr>}</tbody></table></div></Section>
 {editing&&<div className="modal-backdrop" role="presentation" onMouseDown={e=>{if(e.currentTarget===e.target)close()}}><div className="modal-card transport-type-modal" role="dialog" aria-modal="true" aria-label={editing.id?'Edit transport type':'Add transport type'}><div className="modal-head"><div><h2>{editing.id?'Edit':'Add'} transport type</h2><p>Used for operator services, vehicles, routes and customer filter tiles.</p></div><button className="modal-close" onClick={close} disabled={busy} aria-label="Close">×</button></div><div className="modal-body"><div className="form-grid two-col">
  <label className="form-field"><span>Name</span><input name="name" value={form.name||''} onChange={e=>set('name',e.target.value)}/></label>
  <label className="form-field"><span>Code</span><input name="code" value={form.code||''} onChange={e=>set('code',e.target.value)} placeholder="SPEED_BOAT"/></label>
  <label className="form-field"><span>Display order</span><input name="display_order" type="number" min="0" step="1" value={form.display_order??0} onChange={e=>set('display_order',e.target.value)}/></label>
  <label className="form-field full-width"><span>Description</span><textarea name="description" value={form.description||''} onChange={e=>set('description',e.target.value)}/></label>
  <label className="form-field"><span>Tile image URL</span><input name="picture_url" type="url" value={form.picture_url||''} onChange={e=>set('picture_url',e.target.value)}/></label>
  <label className="form-field"><span>Upload tile image</span><input type="file" accept="image/jpeg,image/png,image/webp,image/gif" onChange={e=>setFile(e.target.files?.[0]||null)}/><small>JPEG, PNG, WebP or GIF; maximum 8 MB.</small></label>
  {(preview||form.picture_url)&&<div className="transport-type-preview"><img src={preview||form.picture_url} alt="Transport type tile preview"/></div>}
  <label className="check-row"><input name="active" type="checkbox" checked={!!form.active} onChange={e=>set('active',e.target.checked)}/><span><b>Active transport type</b><small>Available for new operator, route and vehicle assignments.</small></span></label>
 </div>{error&&<p className="action-error" role="alert">{error}</p>}</div><div className="modal-footer"><button className="btn secondary" onClick={close} disabled={busy}>Cancel</button><button className="btn" onClick={save} disabled={busy}>{busy?'Saving…':'Save transport type'}</button></div></div></div>}</>;
}
