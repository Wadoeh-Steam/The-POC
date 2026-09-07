-- 20260907000001's dynamic constraint lookup was wrong: it searched for a
-- constraint matching ONLY the 'field' column's attnum, but the actual
-- original constraint (initial_schema.sql) was the two-column
-- unique(emotion_log_id, field) — never matched, never dropped. Found live
-- 2026-09-07: any second/third answer sharing field='FEELING' (every
-- question in the anchor+followup chain does) hit
-- "duplicate key value violates unique constraint
-- log_context_answers_emotion_log_id_field_key" on insert.

alter table log_context_answers
  drop constraint if exists log_context_answers_emotion_log_id_field_key;

-- 20260907000001's replacement constraint should already exist from that
-- migration; this is just a safety net in case it didn't for the same
-- reason (skipped believing the old one was still needed).
alter table log_context_answers
  drop constraint if exists log_context_answers_entry_sequence_key;
alter table log_context_answers
  add constraint log_context_answers_entry_sequence_key unique (emotion_log_id, sequence);

-- Clean up the incomplete test entry from live debugging today — never
-- shown in the UI (context_complete=false is filtered out client-side)
-- but no reason to leave it.
delete from emotion_logs where id = '9bc4ed0e-3927-4155-b08e-847bafbbe643' and context_complete = false;
