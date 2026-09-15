import {describe,expect,it} from 'vitest';
import {journeyScopeSpec,TERMINAL_JOURNEY_STATUSES} from './journey-scope';

describe('journeyScopeSpec',()=>{
 it('starts the default operational view at midnight today in Antigua',()=>{
  const spec=journeyScopeSpec('operational',new Date('2026-09-15T12:00:00Z'));
  expect(spec.excludedStatuses).toBeUndefined();
  expect(spec.since).toBe('2026-09-15T04:00:00.000Z');
  expect(spec.before).toBeUndefined();
  expect(spec.ascending).toBe(true);
 });

 it('offers today and the next seven Antigua calendar days as bounded filters',()=>{
  const now=new Date('2026-09-15T12:00:00Z');
  expect(journeyScopeSpec('today',now)).toMatchObject({
   since:'2026-09-15T04:00:00.000Z',before:'2026-09-16T04:00:00.000Z',ascending:true,
  });
  expect(journeyScopeSpec('next_7_days',now)).toMatchObject({
   since:'2026-09-15T04:00:00.000Z',before:'2026-09-22T04:00:00.000Z',ascending:true,
  });
 });

 it('makes closed history explicitly available newest first',()=>{
  const spec=journeyScopeSpec('past_closed',new Date('2026-09-15T12:00:00Z'));
  expect(spec.includedStatuses).toEqual(TERMINAL_JOURNEY_STATUSES);
  expect(spec.before).toBe('2026-09-15T04:00:00.000Z');
  expect(spec.ascending).toBe(false);
 });
});
