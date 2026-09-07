-- One-off: flip Radit's fresh dev profile (post-reinstall, created today)
-- to role='child', same pattern as 20260907000004's original flip. Also
-- sets child_consent_at directly — this is a dev/test account, not a real
-- minor, so skipping the in-app consent screen for testing convenience is
-- acceptable here; flagging it explicitly rather than doing it silently.
-- Drops the throwaway lookup table from 20260907000014.

drop table if exists _debug_lookup;

alter table profiles disable trigger profiles_prevent_privilege_escalation;

update profiles
set role = 'child', child_consent_at = now()
where id = '37675f4a-ec68-4e43-8014-9d8608995d4b'
  and role = 'parent';

alter table profiles enable trigger profiles_prevent_privilege_escalation;
