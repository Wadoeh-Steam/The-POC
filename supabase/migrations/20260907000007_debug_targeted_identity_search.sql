-- TEMPORARY diagnostic — existence check only, no identity data copied.
-- Dropped (along with 20260907000006) by the very next migration.

drop table if exists _debug_identities;

create table _debug_identities as
select
  count(*) filter (where user_id = 'c4d13b64-7524-4b7a-9314-46c1cedd92e0') as matches_by_user_id,
  count(*) filter (where identity_data ->> 'email' = '2brrtvbwdd@privaterelay.appleid.com') as matches_by_email,
  count(*) as total_apple_identities
from auth.identities
where provider = 'apple';
