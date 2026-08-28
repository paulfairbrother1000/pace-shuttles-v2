-- Projects can have default function privileges that grant EXECUTE directly
-- to anon. Revoke those direct grants in addition to the PUBLIC revocations in
-- the geography editor migration.
revoke all on function public.v2_admin_save_country(uuid,text,text,text,text,text,boolean,text,text,boolean) from anon;
revoke all on function public.v2_admin_save_pickup(uuid,uuid,text,text,text,text,text,text,text,text,uuid,uuid,text,text,uuid,uuid,numeric,numeric,boolean) from anon;
revoke all on function public.v2_admin_save_destination(uuid,uuid,text,text,text,text,text,text,text,text,text,date,date,text,text,text,text,text,text,text,uuid,uuid,numeric,numeric,boolean) from anon;
revoke all on function public.v2_admin_list_transport_type_places() from anon;
