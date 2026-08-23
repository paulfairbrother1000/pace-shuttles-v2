# Pace Shuttles V2 — Service Scheduling & Access Management

This tranche adds production Site Admin controls for recurring service schedules, controlled departure generation, and authenticated user/role linkage for Site Admin, operator and captain workspaces.

The required protected Supabase views/functions have already been deployed to production. No manual SQL is required.

Important: role-link actions intentionally require the person to have signed in at least once, so operational permissions are never used as an account-creation shortcut.
