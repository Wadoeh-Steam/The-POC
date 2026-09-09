-- The client-side consent screen that was meant to set
-- profiles.child_consent_at (ConsentGateView) was disabled in
-- ios-client@b8a35ff — ChildRootView now routes straight from nickname to
-- RootTabView, skipping it entirely, and recordChildConsent() has no other
-- caller. Since then this policy's `child_consent_at is not null` clause
-- has silently blocked every child account from ever submitting a journal
-- entry (RLS violation on INSERT), surfaced client-side as
-- "Perlu persetujuan orang tua/wali dulu sebelum bisa mengisi jurnal."
--
-- Dropping the requirement rather than restoring the screen (a product
-- decision, not a bug fix) -- child_consent_at itself is left in place,
-- just no longer enforced. Companion to the matching check removed from
-- submit-child-log-entry's own belt-and-suspenders guard.

drop policy if exists emotion_logs_insert_child on emotion_logs;
create policy emotion_logs_insert_child on emotion_logs
  for insert to authenticated
  with check (
    child_id = auth.uid()
    and family_id = auth_family_id()
    and is_child()
  );
