-- Fix: on_parent_log_entry_needs_bridge (20260908000001) broke the live
-- parent guided-journal submit flow. notify_parent_log_entry_needs_bridge
-- calls trigger_edge_function(), which reads vault.decrypted_secrets --
-- but neither function is SECURITY DEFINER, so it runs with the CALLING
-- statement's privileges. submit-parent-log-entry's final UPDATE runs as
-- the parent's own `authenticated` role, which has no vault schema access
-- -> "permission denied for schema vault" -> the whole UPDATE transaction
-- (trigger included) rolls back -> context_complete never flips ->
-- submit-parent-log-entry reports complete_update_failed. Confirmed live
-- 2026-09-08, minutes after deploying 20260908000001.
--
-- The equivalent child-side trigger (on_emotion_log_needs_summary,
-- 20260907000001) never hit this same wall only because it's an
-- INSERT-only trigger checking new.context_complete=true -- but
-- submit-child-log-entry inserts incomplete then UPDATEs, same shape as
-- the parent path, so that trigger's WHEN clause never actually matches
-- and the trigger body never runs at all. Two separate latent bugs
-- (wrong trigger timing + missing SECURITY DEFINER) that happened to mask
-- each other on the child side. Only fixing the permission issue here,
-- for the trigger this migration set introduced; the child-side timing
-- bug is a separate, pre-existing issue out of scope for this migration.
--
-- Same fix pattern already used in this codebase for an identical class
-- of problem: 20260825000002_fix_profiles_rls_recursion.sql's
-- auth_family_id()/auth_role().

create or replace function notify_parent_log_entry_needs_bridge() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform trigger_edge_function('bridge-parent-log-entry', jsonb_build_object(
    'type', 'UPDATE',
    'table', 'parent_log_entries',
    'record', to_jsonb(new)
  ));
  return new;
end;
$$;
