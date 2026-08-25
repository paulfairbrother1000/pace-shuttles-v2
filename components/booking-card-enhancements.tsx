'use client';

import {useEffect} from 'react';

const seatOptions = Array.from({length:12},(_,i)=>i+1);

export default function BookingCardEnhancements(){
  useEffect(()=>{
    const enhance=()=>{
      const topSelect=document.querySelector<HTMLSelectElement>('.ps-planner-head label select');
      if(!topSelect)return;

      document.querySelectorAll<HTMLElement>('.ps-journey').forEach(card=>{
        if(card.classList.contains('ps-unavailable'))return;
        const main=card.querySelector<HTMLElement>('.ps-journey-main');
        const price=card.querySelector<HTMLElement>('.ps-price');
        if(!main||!price||main.querySelector('.ps-card-seats'))return;

        const field=document.createElement('label');
        field.className='ps-card-seats';
        field.innerHTML='<span>Seats</span>';
        const select=document.createElement('select');
        select.setAttribute('aria-label','Seats for this journey');
        seatOptions.forEach(n=>{
          const option=document.createElement('option');
          option.value=String(n);option.textContent=String(n);select.appendChild(option);
        });
        select.value=topSelect.value;
        select.addEventListener('change',()=>{
          topSelect.value=select.value;
          topSelect.dispatchEvent(new Event('change',{bubbles:true}));
        });
        field.appendChild(select);
        const suffix=document.createElement('span');
        suffix.className='ps-card-seats-suffix';suffix.textContent='seats';field.appendChild(suffix);
        price.parentElement?.insertBefore(field,price);
      });
    };

    enhance();
    const observer=new MutationObserver(enhance);
    observer.observe(document.body,{childList:true,subtree:true});
    return()=>observer.disconnect();
  },[]);

  return null;
}
