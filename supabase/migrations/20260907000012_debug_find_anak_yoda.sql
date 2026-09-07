-- TEMPORARY diagnostic — find the child profile(s) in mama yoda's family.
-- Dropped by the very next migration.

drop table if exists _debug_lookup;

create table _debug_lookup as
select id, role, family_id, display_name, llm_mode, child_consent_at, created_at
from profiles
where family_id = 'a936d852-f04d-478a-811e-4d14e6e95395';
