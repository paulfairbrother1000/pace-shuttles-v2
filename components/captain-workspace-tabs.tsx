'use client';

import React from 'react';

export type CaptainWorkspaceTab='today'|'general';

export function captainWorkspaceTab(value:unknown):CaptainWorkspaceTab{
 return value==='general'?'general':'today';
}

export function CaptainWorkspaceTabs({active,onNavigate}:{active:CaptainWorkspaceTab;onNavigate:(tab:CaptainWorkspaceTab)=>void}){
 return <nav className="captain-workspace-tabs" aria-label="Captain workspace">
  {(['today','general'] as const).map(tab=><a
   key={tab}
   href={`/captain?tab=${tab}`}
   aria-current={active===tab?'page':undefined}
   onClick={event=>{if(event.button!==0||event.metaKey||event.ctrlKey||event.shiftKey||event.altKey)return;event.preventDefault();onNavigate(tab)}}
  >{tab==='today'?'Today':'General'}</a>)}
 </nav>;
}
