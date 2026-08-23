# Pace Shuttles V2 — Large Admin / Operations Tranche

## Included in this tranche

- Clearer allocation-engine status wording: confirmed vehicles are labelled as T-24 decisions; discarded/cancelled consideration rows are presented as released/not selected rather than implying the whole journey was cancelled.
- Allocation decision audit panel on Journey Detail using recorded scheduler T-72/T-24 runs, timestamps, engine version, outcome and failures.
- Expanded Site Admin journey controls including live consideration refresh, protected T-72/T-24 processing and journey at-risk controls.
- Support workspace with conversation/message history, ticket selection, claim/assign-to-me, resolution and conversation close actions.
- Configuration / System Health screen with platform users and roles, scheduler history, failed jobs, notification status/failures, country commission and cancellation-policy visibility.
- New protected Site Admin read models for scheduler runs, support messages, voyage logs, notifications and profiles.
- New protected Site Admin RPC wrappers for support actions, manual notifications and departure risk state.
- Existing Finance, Network, Operator, Journey, Analytics and Allocation Engine functionality retained.

## Database

The required Supabase migration has already been applied to the live V2 project.

## Build validation

- TS/TSX source was syntax-parsed with the available global TypeScript compiler.
- Full local Next.js build could not be completed because dependency installation repeatedly timed out in the execution environment.
- Vercel remains the definitive production build check for this package.
