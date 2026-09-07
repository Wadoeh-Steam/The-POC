-- One-off: flip Radit's dev profile to role='child' for on-device testing,
-- bypassing the anti-escalation trigger deliberately. Guarded on current
-- role, so a no-op anywhere this specific id doesn't exist.

alter table profiles disable trigger profiles_prevent_privilege_escalation;

update profiles
set role = 'child'
where id = 'c4d13b64-7524-4b7a-9314-46c1cedd92e0'
  and role = 'parent';

alter table profiles enable trigger profiles_prevent_privilege_escalation;
