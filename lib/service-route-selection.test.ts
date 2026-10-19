import {describe,expect,it} from 'vitest';
import {buildOneOffServiceSchedule,formatServiceRouteChoices,resolveServiceRouteChoice} from './service-route-selection';

const routes=[
 {id:'route-1',route_name:'Jolly Harbour → Nobu'},
 {id:'route-2',route_name:'St Marys Heliport → Nobu'},
];

describe('service route selection',()=>{
 it('lists each route with an explicit number and name',()=>{
  expect(formatServiceRouteChoices(routes)).toBe('1. Jolly Harbour → Nobu\n2. St Marys Heliport → Nobu');
 });

 it('returns the route matching the administrator’s numbered choice',()=>{
  expect(resolveServiceRouteChoice(routes,'2')).toBe(routes[1]);
 });

 it('does not silently fall back to a route for an invalid choice',()=>{
  expect(resolveServiceRouteChoice(routes,'')).toBeNull();
  expect(resolveServiceRouteChoice(routes,'3')).toBeNull();
  expect(resolveServiceRouteChoice(routes,'1.5')).toBeNull();
 });

 it('turns a valid one-off date into a single-day service window',()=>{
  expect(buildOneOffServiceSchedule('2026-11-21')).toEqual({
   daysOfWeek:[6],
   validFrom:'2026-11-21',
   validTo:'2026-11-21',
   recurrenceType:'weekly',
   recurrenceIntervalWeeks:1,
   recurrenceAnchorDate:'2026-11-21',
  });
 });

 it('rejects impossible one-off dates',()=>{
  expect(buildOneOffServiceSchedule('2026-02-30')).toBeNull();
  expect(buildOneOffServiceSchedule('not-a-date')).toBeNull();
 });
});
