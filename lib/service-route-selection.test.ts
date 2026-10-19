import {describe,expect,it} from 'vitest';
import {formatServiceRouteChoices,resolveServiceRouteChoice} from './service-route-selection';

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

});
