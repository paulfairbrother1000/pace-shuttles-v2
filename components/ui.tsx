'use client';
import Link from 'next/link';
import { usePathname, useSearchParams } from 'next/navigation';
import { ReactNode } from 'react';
import { LayoutDashboard, Activity, BookOpen, Users, MapPinned, BarChart3, WalletCards, Headphones, Settings, Menu, ChevronRight, ShipWheel, CircleDollarSign, CarFront, UserRound, Route, Bell, MoreHorizontal } from 'lucide-react';

export function Brand(){ return <div className="brand"><div className="brandmark">P</div><div><b>Pace</b><small>SHUTTLES</small></div></div> }

const nav = [
  ['/admin','Dashboard',LayoutDashboard],['/admin/live-operations','Live Operations',Activity],['/admin/journeys','Journeys',BookOpen],['/admin/operators','Operators',Users],['/admin/network','Routes & Network',MapPinned],['/admin/analytics','Analytics',BarChart3],['/admin/finance','Finance',WalletCards],['/admin/support','Support',Headphones],['/admin/settings','Configuration',Settings]
] as const;

export function AdminShell({children,title,subtitle}:{children:ReactNode,title:string,subtitle?:string}){
  const path=usePathname();
  const params=useSearchParams();
  const operator=params.get('operator');
  return <div className="app-shell">
    <aside className="sidebar"><Brand/><nav>{nav.map(([href,label,Icon])=><Link key={href} href={href} className={path===href||path.startsWith(href+'/')?'active':''}><Icon size={18}/><span>{label}</span></Link>)}</nav><div className="sidebar-footer"><button><Menu size={18}/>Collapse menu</button></div></aside>
    <main className="main"><header className="topbar"><div><h1>{title}</h1>{subtitle&&<p>{subtitle}</p>}</div><div className="top-actions"><select defaultValue="Global"><option>Global</option><option>Antigua & Barbuda</option><option>Barbados</option><option>BVI</option></select><select defaultValue="This Month"><option>Today</option><option>This Month</option><option>Last 30 Days</option></select><button className="icon-btn"><Bell size={18}/></button><div className="avatar">AD</div></div></header>
    {operator&&<div className="operator-banner">Managing operator: <strong>{operator==='barefoot'?'Barefoot':operator}</strong><Link href={path}>Exit operator management</Link></div>}
    <div className="content">{children}</div></main>
    <MobileNav />
  </div>
}

export function MobileNav(){const path=usePathname(); const items=[['/admin','Home',LayoutDashboard],['/admin/live-operations','Operations',Activity],['/admin/journeys','Journeys',BookOpen],['/admin/operators','Operators',Users],['/admin/support','More',MoreHorizontal]] as const; return <nav className="mobile-nav">{items.map(([href,label,Icon])=><Link href={href} key={href} className={path===href||path.startsWith(href+'/')?'active':''}><Icon size={20}/><span>{label}</span></Link>)}</nav>}

export function KpiCard({label,value,delta}:{label:string,value:string,delta?:string}){return <div className="card kpi"><span>{label}</span><strong>{value}</strong>{delta&&<small className="up">↑ {delta}</small>}<div className="spark"><i/><i/><i/><i/><i/><i/><i/></div></div>}
export function Section({title,action,children,className=''}:{title:string,action?:ReactNode,children:ReactNode,className?:string}){return <section className={`card section ${className}`}><div className="section-head"><h2>{title}</h2>{action}</div>{children}</section>}
export function Status({value}:{value:string}){const c=value.toLowerCase().replaceAll(' ','-');return <span className={`status ${c}`}>{value}</span>}
export function Progress({value}:{value:number}){return <div className="progress"><span style={{width:`${Math.min(100,value)}%`}}/></div>}
export function RowLink({href,children}:{href:string,children:ReactNode}){return <Link className="row-link" href={href}>{children}<ChevronRight size={17}/></Link>}
export const VehicleIcon=({type}:{type:string})=> type.includes('Taxi')?<CarFront size={18}/>:<ShipWheel size={18}/>;
export const MoneyIcon=CircleDollarSign;
export const CaptainIcon=UserRound;
export const RouteIcon=Route;
