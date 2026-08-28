-- Repoint only the known public Storage origin. Object paths remain unchanged,
-- so the copied V1 library and all existing record associations stay aligned.
update pace_v2.countries
set picture_url=replace(
 picture_url,
 'https://bopvaaexicvdueidyvjd.supabase.co/storage/v1/object/public/images/',
 'https://prvzgvkuefcflvmepuhd.supabase.co/storage/v1/object/public/images/'
)
where picture_url like 'https://bopvaaexicvdueidyvjd.supabase.co/storage/v1/object/public/images/%';

update pace_v2.pickup_points
set picture_url=replace(
 picture_url,
 'https://bopvaaexicvdueidyvjd.supabase.co/storage/v1/object/public/images/',
 'https://prvzgvkuefcflvmepuhd.supabase.co/storage/v1/object/public/images/'
)
where picture_url like 'https://bopvaaexicvdueidyvjd.supabase.co/storage/v1/object/public/images/%';

update pace_v2.destinations
set picture_url=replace(
 picture_url,
 'https://bopvaaexicvdueidyvjd.supabase.co/storage/v1/object/public/images/',
 'https://prvzgvkuefcflvmepuhd.supabase.co/storage/v1/object/public/images/'
)
where picture_url like 'https://bopvaaexicvdueidyvjd.supabase.co/storage/v1/object/public/images/%';
