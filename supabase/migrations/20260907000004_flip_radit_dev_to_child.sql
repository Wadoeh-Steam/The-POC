-- One-off: flip Radit's dev profile to role='child' for on-device testing
-- of the child guided-journal flow, without needing a second Apple ID.
-- profiles_prevent_privilege_escalation blocks role changes via normal
-- UPDATE by design (stops this happening by accident from a client) — this
-- disables it just for this one intentional admin operation.
-- Guarded on current role so it's a no-op if already flipped or the row
-- doesn't match (safe to apply anywhere this specific id doesn't exist).

alter table profiles disable trigger profiles_prevent_privilege_escalation;

update profiles
set role = 'child'
where id = 'c4d13b64-7524-4b7a-9314-46c1cedd92e0'
  and role = 'parent';

alter table profiles enable trigger profiles_prevent_privilege_escalation;
