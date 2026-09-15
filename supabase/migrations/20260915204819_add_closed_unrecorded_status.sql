-- PostgreSQL enum additions must commit before later migration statements use
-- the new value.  Keep this migration intentionally isolated.
alter type pace_v2.departure_status
  add value if not exists 'closed_unrecorded';
