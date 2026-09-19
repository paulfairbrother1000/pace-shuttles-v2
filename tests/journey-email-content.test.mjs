import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';
import ts from 'typescript';

const modulePath = new URL('../lib/journey-email-content.ts', import.meta.url);
const customerEmailPath = new URL('../lib/customer-email.ts', import.meta.url);

async function loadEmailContent() {
  assert.equal(existsSync(modulePath), true, 'journey email content module is missing');
  const source = readFileSync(modulePath, 'utf8');
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  return import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`);
}

async function loadCustomerEmail() {
  const source = readFileSync(customerEmailPath, 'utf8')
    .replace("import {createClient} from '@supabase/supabase-js';", '')
    .replace("import {buildJourneyBroadcastEmail,type JourneyBroadcastCategory} from './journey-broadcast-email';", "const buildJourneyBroadcastEmail=(input)=>({subject:'Journey update',text:input.message});")
    .replace("import {buildFeedbackEmail} from './feedback-email-content';", "const buildFeedbackEmail=()=>({subject:'Feedback',text:'Feedback'});")
    .replace("import {buildT72OperatorEmail,type T72OperatorEmailInput} from './t72-operator-email';", "const buildT72OperatorEmail=(input)=>({subject:'Under consideration',text:input.journeyName});")
    .replace("import {buildCaptainPendingJourneyEmail,type CaptainPendingJourneyEmailInput} from './journey-email-content';", "const buildCaptainPendingJourneyEmail=()=>({subject:'Captain pending',text:'Captain pending'});");
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  return import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`);
}

test('wet destination reminder includes the approved allocation, directions and wet-arrival advice', async () => {
  const { buildTomorrowJourneyEmail } = await loadEmailContent();
  const email = buildTomorrowJourneyEmail({
    firstName: 'Paul', countryName: 'British Virgin Islands', pickupName: 'Nanny Cay Marina',
    destinationName: 'The Soggy Dollar', departureLocalLabel: '12:00 PM', arrivalByLocalLabel: '11:45 AM',
    captainFullName: 'James Williams', captainSurname: 'Williams', vehicleType: 'Speed Boat',
    vehicleName: 'Sea Runner', pickupDirectionsUrl: 'https://maps.app.goo.gl/example', wetDestination: true
  });

  assert.equal(email.subject, 'Your Journey to The Soggy Dollar is Tomorrow!');
  assert.equal(email.text, `Hi Paul,

The time is almost upon us!

Your journey from Nanny Cay Marina to The Soggy Dollar at 12:00 PM is scheduled with Captain James Williams aboard the Speed Boat Sea Runner.

Please arrive at Nanny Cay Marina no later than 11:45 AM.

Get directions to your pickup point
https://maps.app.goo.gl/example

Please prepare for a wet arrival

There is no mooring at The Soggy Dollar, so you will get wet when you disembark. Please bring a towel and any suitable clothing or footwear you may require.

Need to contact your captain on the day of travel?

Sign in to My Journeys (https://www.paceshuttles.com/customer), select this booking and open Help & Support. Choose Day of Travel, write your message and select Contact captain.

Your captain will receive the message through Pace Shuttles. This secure conversation will remain available until four hours after your journey is completed.

We hope you have a wonderful journey to The Soggy Dollar with Captain Williams.

Regards,
The Pace Shuttles Team`);
});

test('dry destination reminder omits the wet-arrival section', async () => {
  const { buildTomorrowJourneyEmail } = await loadEmailContent();
  const email = buildTomorrowJourneyEmail({
    firstName: 'Paul', countryName: 'British Virgin Islands', pickupName: 'Nanny Cay Marina',
    destinationName: 'Cane Garden Bay', departureLocalLabel: '12:00 PM', arrivalByLocalLabel: '11:45 AM',
    captainFullName: 'James Williams', captainSurname: 'Williams', vehicleType: 'Speed Boat',
    vehicleName: 'Sea Runner', pickupDirectionsUrl: 'https://maps.app.goo.gl/example', wetDestination: false
  });
  assert.doesNotMatch(email.text, /Please prepare for a wet arrival|There is no mooring/);
  assert.match(email.text, /Get directions to your pickup point\nhttps:\/\/maps\.app\.goo\.gl\/example/);
});

test('captain-pending reminder gives the customer specific journey and vehicle details without inventing an operational captain', async () => {
  const { buildCaptainPendingJourneyEmail } = await loadEmailContent();
  const email = buildCaptainPendingJourneyEmail({
    firstName: 'Paul', pickupName: "St John's", destinationName: 'Nikki Beach',
    departureDateLabel: 'Sunday, 20 September 2026', departureLocalLabel: '10:00 AM',
    arrivalByLocalLabel: '9:45 AM', vehicleType: 'Speed Boat', vehicleName: 'Sea Sea Rider',
    pickupDirectionsUrl: 'https://maps.app.goo.gl/example', wetDestination: true
  });

  assert.equal(email.subject, 'Your Pace Shuttles journey is tomorrow – captain confirmation pending');
  assert.equal(email.text, `Hi Paul,

Your Speed Boat Sea Sea Rider is scheduled for the following journey.

Date: Sunday, 20 September 2026
Time: 10:00 AM
Journey: St John's to Nikki Beach
Vehicle: Speed Boat Sea Sea Rider
Assigned captain: To be confirmed

We are finalising the captain assignment and will send you an update as soon as it is confirmed. Your booking remains active and no action is required from you.

Please arrive at St John's no later than 9:45 AM.

Get directions to your pickup point
https://maps.app.goo.gl/example

Please prepare for a wet arrival

There is no mooring at Nikki Beach, so you will get wet when you disembark. Please bring a towel and any suitable clothing or footwear you may require.

Regards,
The Pace Shuttles Team`);
  assert.doesNotMatch(email.text, /contact your captain|Captain To be confirmed aboard/i);
});

test('customer-provided names are escaped while directions retain a safe exact link target', async () => {
  const [{ buildTomorrowJourneyEmail }, { renderCustomerEmailHtml }] = await Promise.all([loadEmailContent(), loadCustomerEmail()]);
  const email = buildTomorrowJourneyEmail({
    firstName: '<Paul & Co>', countryName: 'British Virgin Islands', pickupName: 'Nanny <Cay>',
    destinationName: 'The "Soggy" Dollar', departureLocalLabel: '12:00 PM', arrivalByLocalLabel: '11:45 AM',
    captainFullName: 'James Williams', captainSurname: 'Williams', vehicleType: 'Speed Boat',
    vehicleName: 'Sea Runner', pickupDirectionsUrl: 'https://maps.app.goo.gl/example', wetDestination: false
  });
  assert.match(email.subject, /The "Soggy" Dollar/);
  assert.match(email.text, /Hi <Paul & Co>,/);
  assert.match(email.text, /Nanny <Cay>/);
  const html = renderCustomerEmailHtml(email.subject, `${email.text}\nSee https://maps.app.goo.gl/example).`);
  assert.match(html, /Hi &lt;Paul &amp; Co&gt;,/);
  assert.match(html, /Nanny &lt;Cay&gt;/);
  assert.match(html, /href="https:\/\/maps\.app\.goo\.gl\/example"/);
  assert.doesNotMatch(html, /href="https:\/\/maps\.app\.goo\.gl\/example\)\./);
});

test('linkifier excludes raw and escaped adjacent closing delimiters from href targets', async () => {
  const { renderCustomerEmailHtml } = await loadCustomerEmail();
  const url = 'https://maps.app.goo.gl/example';
  for (const delimiter of [')', ']', '}', '"', '>', "'"]) {
    const html = renderCustomerEmailHtml('Directions', `Open ${url}${delimiter}`);
    assert.match(html, new RegExp(`href="${url}"`));
    assert.doesNotMatch(html, new RegExp(`href="${url.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[^" ]+"`));
  }
  assert.match(renderCustomerEmailHtml('Directions', `Open ${url}),`), /href="https:\/\/maps\.app\.goo\.gl\/example"/);
});

test('operator lifecycle emails link to the Operator Portal instead of My Journeys', async () => {
  const { renderCustomerEmailHtml } = await loadCustomerEmail();
  const html = renderCustomerEmailHtml(
    'Journey under consideration',
    'Review this journey in the Operator Portal.',
    'T72_UNDER_CONSIDERATION'
  );
  assert.match(html, /href="https:\/\/www\.paceshuttles\.com\/operator"[^>]*>Operator Portal<\/a>/);
  assert.doesNotMatch(html, />My Journeys<\/a>/);
});
