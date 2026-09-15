import {describe,expect,it} from 'vitest';
import {phaseLabel,schedulerRunDuration,schedulerRunImpact,schedulerRunResolution,schedulerRunSummary} from './scheduler-history';

const run={
 started_at:'2026-09-15T17:00:09Z',finished_at:'2026-09-15T17:02:15Z',status:'failed',execution_source:'scheduled',
 failure_phase:'journey_operations',failure_reason:'upstream request timeout',
 impact_summary:'No T-72 or T-24 lifecycle changes committed; later phases did not run.',
 result:{operations:{generated_departures:3,t72_processed:2,t24_processed:1,closed_unrecorded:1},t24_queued:4,feedback_queued:2,emails:{claimed:5,sent:4,failed:1}},
 resolution_summary:'Resolved by successful scheduled run at 2026-09-15 21:00:12 UTC.',
};

describe('scheduler history presentation',()=>{
 it('labels the four operational phases in plain language',()=>{
  expect(phaseLabel('journey_operations')).toBe('Journey operations');
  expect(phaseLabel('t24_communications')).toBe('T-24 communications');
  expect(phaseLabel('feedback_communications')).toBe('Feedback communications');
  expect(phaseLabel('email_delivery')).toBe('Email delivery');
 });
 it('derives duration and a concise count summary from recorded results',()=>{
  expect(schedulerRunDuration(run)).toBe('2m 6s');
  expect(schedulerRunSummary(run)).toBe('Generated 3 · T-72 2 · T-24 1 · Closed 1 · Emails 4 sent / 1 failed');
 });
 it('uses persisted impact and resolution evidence without inventing delivery',()=>{
  expect(schedulerRunImpact(run)).toBe('No T-72 or T-24 lifecycle changes committed; later phases did not run.');
  expect(schedulerRunResolution(run)).toBe('Resolved by successful scheduled run at 2026-09-15 21:00:12 UTC.');
  expect(schedulerRunResolution({...run,resolution_summary:null})).toBe('Unresolved');
 });
});
