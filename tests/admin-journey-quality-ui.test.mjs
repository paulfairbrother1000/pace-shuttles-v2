import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const read=path=>readFileSync(new URL(`../${path}`,import.meta.url),'utf8');

test('Site Admin consumes the communications foundation and supervises journey replies',()=>{
 const data=read('lib/data.ts');
 const pages=read('components/pages.tsx');
 const ui=read('components/admin-journey-communications.tsx');

 for(const view of [
  'v2_admin_operational_alerts',
  'v2_admin_journey_conversations',
  'v2_admin_journey_messages',
  'v2_admin_journey_broadcast_deliveries',
 ])assert.match(data,new RegExp(view));
 assert.match(data,/v2_site_admin_reply_journey_conversation/);
 assert.match(pages,/<AdminJourneyCommunications/);
 for(const contract of [
  /T-24 details overdue/i,
  /late minutes/i,
  /email failure/i,
  /provider status/i,
  /journey conversations/i,
  /reply as Pace Shuttles/i,
  /broadcast delivery counts/i,
  /active alerts/i,
  /resolved alerts/i,
 ])assert.match(ui,contract);
});

test('Site Admin quality reporting keeps platform, operator, captain and location measures separate',()=>{
 const data=read('lib/data.ts');
 const pages=read('components/pages.tsx');
 const ui=read('components/admin-quality-performance.tsx');

 assert.match(data,/loadAdminCustomerFeedback/);
 assert.match(data,/loadAdminQualityEvidence/);
 assert.match(pages,/<AdminQualityPerformance/);
 for(const contract of [
  /Pace Shuttles quality/i,
  /NPS/i,
  /promoters/i,
  /passives/i,
  /detractors/i,
  /booking experience/i,
  /response count/i,
  /trend/i,
  /recent comments/i,
  /operator quality/i,
  /60% operator \/ 40% captain/i,
  /attribution state/i,
  /captain performance/i,
  /pickup performance/i,
  /destination performance/i,
  /country comparison/i,
  /1–2 star review alerts/i,
 ])assert.match(ui,contract);
});
