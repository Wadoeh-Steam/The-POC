-- Fix: summarize-child-log-entry and generate-how-to-react never fire for
-- the guided-journal child submission flow (submit-child-log-entry).
--
-- Both webhooks are wired as AFTER INSERT triggers with `when
-- (new.context_complete = true)` (20260814000003_webhooks.sql,
-- 20260907000001_child_guided_journal_flow.sql). That's correct for a
-- single-step insert-already-complete row (the original design, and still
-- how the seed data was loaded), but submit-child-log-entry inserts the
-- row with context_complete=false, writes answers, THEN UPDATEs
-- context_complete=true (same insert-then-flip shape as
-- submit-parent-log-entry, see that function's own comment) -- an
-- INSERT-only trigger's WHEN clause never matches that second step, so it
-- silently never fires for any real guided-journal submission.
--
-- Confirmed live 2026-09-09: every emotion_logs row from the last week of
-- real guided-journal submissions has parent_facing_summary = null
-- (summarize-child-log-entry never ran), and how_to_react_tips' newest row
-- is from 2026-09-02 -- six days of real submissions with zero tips
-- generated, despite dozens of context_complete=true rows in that window.
--
-- Fix: add UPDATE triggers for the false->true transition, alongside the
-- existing INSERT triggers (kept as-is, still correct for a single-step
-- insert-complete row -- no double-fire risk, a row that's UPDATEd here
-- was never matched by the INSERT trigger in the first place since it was
-- inserted incomplete).
--
-- Also: same SECURITY DEFINER fix as 20260908000002 for the identical
-- reason -- notify_emotion_log_needs_summary/notify_emotion_log_context_
-- complete call trigger_edge_function(), which reads vault.decrypted_
-- secrets. Without SECURITY DEFINER this runs with the calling
-- statement's privileges; submit-child-log-entry's context_complete
-- UPDATE runs as the child's own `authenticated` role, which has no vault
-- access -- fixing only the trigger timing without this would break the
-- child's own submission the same way it broke the parent's.

create or replace function notify_emotion_log_needs_summary() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform trigger_edge_function('summarize-child-log-entry', jsonb_build_object(
    'type', 'UPDATE',
    'table', 'emotion_logs',
    'record', to_jsonb(new)
  ));
  return new;
end;
$$;

create or replace function notify_emotion_log_context_complete() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform trigger_edge_function('generate-how-to-react', jsonb_build_object(
    'type', 'UPDATE',
    'table', 'emotion_logs',
    'record', to_jsonb(new)
  ));
  return new;
end;
$$;

drop trigger if exists on_emotion_log_needs_summary_on_update on emotion_logs;
create trigger on_emotion_log_needs_summary_on_update
  after update on emotion_logs
  for each row
  when (new.context_complete = true and old.context_complete is distinct from true)
  execute function notify_emotion_log_needs_summary();

drop trigger if exists on_emotion_log_context_complete_on_update on emotion_logs;
create trigger on_emotion_log_context_complete_on_update
  after update on emotion_logs
  for each row
  when (new.context_complete = true and old.context_complete is distinct from true)
  execute function notify_emotion_log_context_complete();
