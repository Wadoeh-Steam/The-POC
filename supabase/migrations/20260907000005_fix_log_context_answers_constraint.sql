-- 20260907000001's dynamic lookup matched only the 'field' column's
-- attnum, but the real original constraint was the two-column
-- unique(emotion_log_id, field) — never matched, never dropped. Any
-- second/third answer sharing field='FEELING' hit a duplicate-key error.

alter table log_context_answers
  drop constraint if exists log_context_answers_emotion_log_id_field_key;

alter table log_context_answers
  drop constraint if exists log_context_answers_entry_sequence_key;
alter table log_context_answers
  add constraint log_context_answers_entry_sequence_key unique (emotion_log_id, sequence);

-- Incomplete test entry from live debugging today — never shown in the UI, cleaned up regardless.
delete from emotion_logs where id = '9bc4ed0e-3927-4155-b08e-847bafbbe643' and context_complete = false;
