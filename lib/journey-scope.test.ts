import {describe,expect,it} from 'vitest';
import {journeyScopeSpec,TERMINAL_JOURNEY_STATUSES} from './journey-scope';

describe('journeyScopeSpec',()=>{
 it('keeps operational work current and excludes terminal statuses',()=>{
  const spec=journeyScopeSpec('operational',new Date('2026-09-15T12:00:00Z'));
  expect(spec.excludedStatuses).toEqual(TERMINAL_JOURNEY_STATUSES);
  expect(spec.since).toBe('2026-09-14T04:00:00.000Z');
  expect(spec.ascending).toBe(true);
 });

 it('makes closed history explicitly available newest first',()=>{
  const spec=journeyScopeSpec('past_closed',new Date('2026-09-15T12:00:00Z'));
  expect(spec.includedStatuses).toEqual(TERMINAL_JOURNEY_STATUSES);
  expect(spec.before).toBe('2026-09-15T12:00:00.000Z');
  expect(spec.ascending).toBe(false);
 });
});
