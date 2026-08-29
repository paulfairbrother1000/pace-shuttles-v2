-- Anonymous browser traffic may read only the deliberately public catalogue
-- views. Customer, operator, captain and Site Admin views require a session.
do $restrict_anon_reads$
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
      and c.relname not like 'v2\_public\_%' escape '\'
  loop
    execute format(
      'revoke select on table %I.%I from anon',
      v_view.schema_name,
      v_view.view_name
    );
  end loop;
end
$restrict_anon_reads$;
