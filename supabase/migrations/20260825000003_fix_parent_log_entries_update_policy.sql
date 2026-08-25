-- Fix missing UPDATE policy on parent_log_entries.
--
-- submit-parent-log-entry inserts the entry with context_complete=false,
-- writes the answers, then UPDATEs context_complete=true — but only
-- SELECT/INSERT policies existed on this table (20260825000001). With no
-- UPDATE policy, RLS silently matches zero rows for the UPDATE (not an
-- error PostgREST surfaces), so the function reports success while
-- context_complete never actually flips. Found live (2026-08-25) — the
-- row landed in the DB with all 3 answers, but context_complete stayed
-- false.

create policy parent_log_entries_update_own on parent_log_entries
  for update to authenticated
  using (family_id = auth_family_id() and is_parent() and parent_id = auth.uid())
  with check (family_id = auth_family_id() and is_parent() and parent_id = auth.uid());
