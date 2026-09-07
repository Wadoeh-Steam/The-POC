-- TEMPORARY diagnostic — targeted lookup by email, joined with profiles.
-- No broad dump. Dropped by the very next migration.

drop table if exists _debug_lookup;

create table _debug_lookup as
select
  u.id as user_id,
  u.email,
  p.role,
  p.family_id,
  p.display_name,
  p.child_consent_at
from auth.users u
left join public.profiles p on p.id = u.id
where u.email = 'fathiazalfajr@gmail.com';
