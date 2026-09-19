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
    .replace("import {buildCaptainPendingJourneyEmail,buildTomorrowJourneyEmail,type CaptainPendingJourneyEmailInput,type TomorrowJourneyEmailInput} from './journey-email-content';", "const buildCaptainPendingJourneyEmail=()=>({subject:'Captain pending',text:'Captain pending'});const buildTomorrowJourneyEmail=()=>({subject:'Tomorrow',text:'Tomorrow'});");
  const compiled = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  return import(`data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`);
}

test('paired return reminder contains the complete approved itinerary and wet-arrival advice', async () => {
  const { buildTomorrowJourneyEmail } = await loadEmailContent();
  const email = buildTomorrowJourneyEmail({
    firstName: 'Paul', countryName: 'Antigua', pickupName: "St John's",
    destinationName: 'Nikki Beach', outboundPickupTimeLabel: '10:00 AM',
    outboundArrivalByTimeLabel: '9:45 AM', returnPickupTimeLabel: '5:00 PM',
    returnArrivalByTimeLabel: '4:45 PM', adultCount: 2, childCount: 1,
    infantCount: 0, captainFullName: 'Stevie Steve', captainSurname: 'Steve',
    vehicleType: 'Speed Boat', vehicleName: 'Silver Lady', wetDestination: true
  });

  assert.equal(email.subject, "Reminder of Itinerary for St John's to Nikki Beach tomorrow");
  assert.equal(email.text, `Hi Paul

Your Pace Shuttles return journey in Antigua between St John's and Nikki Beach is almost upon us.

Your Speed Boat and captain have now been assigned to your trip.

Speed Boat:
Silver Lady

Captain: Stevie Steve

Here is a reminder of your itinerary details.

Party of 2 adults, 1 child and 0 infants

Journey 1: St John's to Nikki Beach

Pick up time: 10:00 AM

Please be at the Speed Boat by 9:45 AM

Journey 2: Nikki Beach to St John's

Pick up time: 5:00 PM

Please be at the Speed Boat by 4:45 PM

Nikki Beach is a wet arrival destination, meaning you and your party will get wet. Please make sure you have appropriate clothes and a towel with this in mind.

Contacting Us

On the day of the journey, you can contact Captain Steve if necessary using My Journeys > Help & Support > Contact the Captain in the Pace Shuttles portal.

We hope you have a great return trip to Nikki Beach with Captain Steve onboard Silver Lady.

Bon voyage!

The Pace Shuttles Team`);
});

test('dry destination reminder omits the wet-arrival section', async () => {
  const { buildTomorrowJourneyEmail } = await loadEmailContent();
  const email = buildTomorrowJourneyEmail({
    firstName: 'Paul', countryName: 'British Virgin Islands', pickupName: 'Nanny Cay Marina',
    destinationName: 'Cane Garden Bay', outboundPickupTimeLabel: '12:00 PM',
    outboundArrivalByTimeLabel: '11:45 AM', returnPickupTimeLabel: '5:00 PM',
    returnArrivalByTimeLabel: '4:45 PM', adultCount: 1, childCount: 0,
    infantCount: 0, captainFullName: 'James Williams', captainSurname: 'Williams',
    vehicleType: 'Speed Boat', vehicleName: 'Sea Runner', wetDestination: false
  });
  assert.doesNotMatch(email.text, /wet arrival destination|appropriate clothes and a towel/);
  assert.match(email.text, /Journey 2: Cane Garden Bay to Nanny Cay Marina/);
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
    destinationName: 'The "Soggy" Dollar', outboundPickupTimeLabel: '12:00 PM',
    outboundArrivalByTimeLabel: '11:45 AM', returnPickupTimeLabel: '5:00 PM',
    returnArrivalByTimeLabel: '4:45 PM', adultCount: 1, childCount: 0,
    infantCount: 0, captainFullName: 'James Williams', captainSurname: 'Williams',
    vehicleType: 'Speed Boat', vehicleName: 'Sea Runner', wetDestination: false
  });
  assert.match(email.subject, /The "Soggy" Dollar/);
  assert.match(email.text, /Hi <Paul & Co>\n/);
  assert.match(email.text, /Nanny <Cay>/);
  const html = renderCustomerEmailHtml(email.subject, `${email.text}\nSee https://maps.app.goo.gl/example).`);
  assert.match(html, /Hi &lt;Paul &amp; Co&gt;<br\/>/);
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
