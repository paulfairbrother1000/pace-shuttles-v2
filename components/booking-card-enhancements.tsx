'use client';

import {useEffect} from 'react';
import {getSupabaseBrowserClient} from '@/lib/supabase';

const seatOptions = Array.from({length:12},(_,i)=>i+1);
const money=(c:number)=>new Intl.NumberFormat('en-US',{style:'currency',currency:'USD',maximumFractionDigits:0}).format((c||0)/100);

function departureIdFor(card:HTMLElement){
  const ownProps=Object.getOwnPropertyNames(card);
  const fiberKey=ownProps.find(key=>key.startsWith('__reactFiber$'));
  let fiber=fiberKey?(card as any)[fiberKey]:null;
  for(let i=0;fiber&&i<24;i++,fiber=fiber.return){
    if(typeof fiber.key==='string'&&fiber.key)return fiber.key;
    const props=fiber.memoizedProps||fiber.pendingProps;
    const explicit=props?.['data-departure-id'];
    if(typeof explicit==='string'&&explicit)return explicit;
  }
  return card.dataset.departureId||'';
}

export default function BookingCardEnhancements(){
  useEffect(()=>{
    const supabase=getSupabaseBrowserClient();
    if(!supabase)return;

    let forcedDefault=false;

    const enhance=()=>{
      // The old page-level Seats selector is no longer the booking control. Keep
      // the underlying search at one seat and hide the global selector so each
      // journey record owns its own independent party size.
      const topSelect=document.querySelector<HTMLSelectElement>('.ps-planner-head label select');
      if(topSelect){
        const topLabel=topSelect.closest('label') as HTMLElement|null;
        if(topLabel)topLabel.style.display='none';
        if(!forcedDefault){
          forcedDefault=true;
          if(topSelect.value!=='1'){
            topSelect.value='1';
            topSelect.dispatchEvent(new Event('change',{bubbles:true}));
            return;
          }
        }
      }

      document.querySelectorAll<HTMLElement>('.ps-journey').forEach(card=>{
        if(card.classList.contains('ps-unavailable'))return;
        const main=card.querySelector<HTMLElement>('.ps-journey-main');
        const price=card.querySelector<HTMLElement>('.ps-price');
        const action=card.querySelector<HTMLButtonElement>('.ps-actions .ps-primary');
        if(!main||!price||!action||main.querySelector('.ps-card-seats'))return;

        const departureId=departureIdFor(card);
        if(!departureId)return;

        const field=document.createElement('label');
        field.className='ps-card-seats';
        field.innerHTML='<span>Seats</span>';
        const select=document.createElement('select');
        select.setAttribute('aria-label','Seats for this journey');
        seatOptions.forEach(n=>{
          const option=document.createElement('option');
          option.value=String(n);option.textContent=String(n);select.appendChild(option);
        });
        select.value='1';
        field.appendChild(select);
        const suffix=document.createElement('span');
        suffix.className='ps-card-seats-suffix';suffix.textContent='seat';field.appendChild(suffix);
        price.parentElement?.insertBefore(field,price);

        const renderQuote=(q:any,partySize:number)=>{
          const label=price.querySelector('span');
          const strong=price.querySelector('strong');
          const small=price.querySelector('small');
          card.classList.remove('ps-unavailable');
          if(label)label.textContent='Per seat incl. tax & fees';
          if(strong){strong.textContent=money(q.all_in_unit_price_cents);strong.classList.remove('ps-price-loading')}
          if(small)small.textContent=`${partySize} seat${partySize===1?'':'s'} · ${money(q.all_in_total_cents)} total`;
          action.disabled=false;action.textContent='Continue';
        };

        const reprice=async()=>{
          const partySize=Number(select.value)||1;
          suffix.textContent=partySize===1?'seat':'seats';
          const strong=price.querySelector('strong');
          const small=price.querySelector('small');
          if(strong){strong.textContent='Checking…';strong.classList.add('ps-price-loading')}
          if(small)small.textContent='Calculating the best current price for this journey.';
          action.disabled=true;action.textContent='Checking price…';
          const {data,error}=await supabase.rpc('v2_public_quote',{p_departure_id:departureId,p_party_size:partySize});
          const q=(data as any)?.[0];
          if(error||!q||q.quote_status!=='offer'){
            card.classList.add('ps-unavailable');
            if(strong){strong.textContent='Unavailable';strong.classList.remove('ps-price-loading')}
            if(small)small.textContent='Your selected party size cannot be accommodated together on this departure.';
            action.disabled=true;action.textContent='Unavailable';
            return;
          }
          renderQuote(q,partySize);
        };

        select.addEventListener('change',()=>{void reprice()});
        action.addEventListener('click',async event=>{
          event.preventDefault();event.stopPropagation();event.stopImmediatePropagation();
          const partySize=Number(select.value)||1;
          action.disabled=true;action.textContent='Holding price…';
          const {data,error}=await supabase.rpc('v2_public_create_quote_intent',{p_departure_id:departureId,p_party_size:partySize});
          if(error||!data){action.disabled=false;action.textContent='Continue';return}
          window.location.href='/checkout?q='+encodeURIComponent(String(data));
        },true);

        void reprice();
      });
    };

    enhance();
    const observer=new MutationObserver(enhance);
    observer.observe(document.body,{childList:true,subtree:true});
    return()=>observer.disconnect();
  },[]);

  return null;
}
