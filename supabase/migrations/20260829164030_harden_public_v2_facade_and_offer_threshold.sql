-- The public V2 schema is an API facade. Reads are granted deliberately per
-- view, while every mutation must pass through an access-checked RPC.
do $revoke_view_writes$
declare
  v_view record;
begin
  for v_view in
    select n.nspname as schema_name, c.relname as view_name
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'v'
      and c.relname like 'v2\_%' escape '\'
  loop
    execute format(
      'revoke insert, update, delete, truncate, references, trigger on table %I.%I from public, anon, authenticated',
      v_view.schema_name,
      v_view.view_name
    );
  end loop;
end
$revoke_view_writes$;

-- SQL CHECK constraints accept UNKNOWN, so the custom-threshold branch must
-- state non-nullness explicitly rather than relying on numeric comparisons.
alter table pace_v2.vehicle_route_offers
  drop constraint vehicle_route_offer_below_minimum_mode_check;

alter table pace_v2.vehicle_route_offers
  add constraint vehicle_route_offer_below_minimum_mode_check
  check (
    below_minimum_operation_mode in ('never', 'route_default', 'custom_threshold')
    and (
      (
        below_minimum_operation_mode = 'custom_threshold'
        and min_value_threshold_ratio is not null
        and min_value_threshold_ratio > 0
        and min_value_threshold_ratio <= 1
      )
      or (
        below_minimum_operation_mode <> 'custom_threshold'
        and min_value_threshold_ratio is null
      )
    )
  );
