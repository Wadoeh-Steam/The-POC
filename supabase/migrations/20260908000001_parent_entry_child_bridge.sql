-- Bridge for the parent->child direction: when a parent's guided-journal
-- entry (parent_log_entries) reaches context_complete, an Edge Function
-- generates a protective reframe of it for the CHILD to read -- never the
-- parent's raw insight_text. Companion to 20260907000001's child->parent
-- direction (parent_facing_summary), but a DIFFERENT philosophy on
-- purpose: that side preserves substance faithfully (never softens); this
-- side is allowed to genuinely soften/reframe harsh judgment, because a
-- child reading raw parental judgment is a different harm profile than a
-- parent reading a paraphrased child complaint.

alter table parent_log_entries add column if not exists child_facing_summary text;
comment on column parent_log_entries.child_facing_summary is
  'Written by bridge-parent-log-entry -- a protective reframe of the parent''s entry for the '
  'child to read: preserves the TOPIC (what the entry was about) but may fully rewrite tone '
  'and judgment. NULL means: not generated yet, OR the entry was flagged as a genuine safety '
  'concern (not just harsh judgment) and deliberately withheld rather than reframed -- the '
  'child sees the existing generic placeholder either way. The child must never receive the '
  'parent''s raw insight_text.';

-- Webhook: parent_log_entries reaching context_complete=true fires
-- bridge-parent-log-entry. submit-parent-log-entry inserts the row
-- incomplete then flips it via UPDATE (see that function's own comment) --
-- an INSERT-only trigger (the pattern 20260907000001 used for
-- emotion_logs, which never actually fires for that same insert-then-
-- update shape) would never fire here either, since context_complete is
-- always false at insert time. UPDATE trigger instead, guarded to the
-- false->true transition only, not every subsequent update to the row.

create or replace function notify_parent_log_entry_needs_bridge() returns trigger
language plpgsql
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

drop trigger if exists on_parent_log_entry_needs_bridge on parent_log_entries;
create trigger on_parent_log_entry_needs_bridge
  after update on parent_log_entries
  for each row
  when (new.context_complete = true and old.context_complete is distinct from true)
  execute function notify_parent_log_entry_needs_bridge();
