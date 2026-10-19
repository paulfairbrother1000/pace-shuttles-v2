-- These deferred validation triggers inspect private captain assignment rows.
-- Run them with the table owner's rights and an empty search_path so the
-- authenticated caller does not need direct SELECT access to those rows.
create or replace function pace_v2.validate_captain_record_change()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_allocation_id uuid;
  v_captain_id uuid;
begin
  if tg_op='DELETE' then
    v_captain_id:=old.id;
  else
    v_captain_id:=new.id;
  end if;

  for v_allocation_id in
    select distinct assignment.confirmed_allocation_id
    from pace_v2.captain_assignments assignment
    where assignment.captain_id=v_captain_id
  loop
    perform pace_v2.assert_confirmed_allocation_has_eligible_captain(v_allocation_id);
  end loop;

  if tg_op='DELETE' then return old; end if;
  return new;
end
$function$;

create or replace function pace_v2.validate_captain_eligibility_change()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_captain_id uuid;
  v_allocation_id uuid;
begin
  if tg_op<>'INSERT' then
    v_captain_id:=old.captain_id;
    for v_allocation_id in
      select distinct assignment.confirmed_allocation_id
      from pace_v2.captain_assignments assignment
      where assignment.captain_id=v_captain_id
    loop
      perform pace_v2.assert_confirmed_allocation_has_eligible_captain(v_allocation_id);
    end loop;
  end if;

  if tg_op='INSERT' or old.captain_id is distinct from new.captain_id then
    v_captain_id:=new.captain_id;
    for v_allocation_id in
      select distinct assignment.confirmed_allocation_id
      from pace_v2.captain_assignments assignment
      where assignment.captain_id=v_captain_id
    loop
      perform pace_v2.assert_confirmed_allocation_has_eligible_captain(v_allocation_id);
    end loop;
  end if;

  if tg_op='DELETE' then return old; end if;
  return new;
end
$function$;