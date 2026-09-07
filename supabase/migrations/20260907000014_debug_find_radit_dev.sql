-- TEMPORARY diagnostic — find the current "radit dev" profile, if any.
-- Dropped by the very next migration.

drop table if exists _debug_lookup;

create table _debug_lookup as
select id, role, family_id, display_name, llm_mode, child_consent_at, created_at
from profiles
where display_name ilike '%radit%';
