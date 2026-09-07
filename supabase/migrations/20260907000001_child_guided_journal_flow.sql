-- Child guided-journal flow: writes to the ORIGINAL emotion_logs/
-- log_context_answers tables (not a new pair) — generate-overview already
-- queries these as the "child signal" in its bidirectional prompt, just
-- dead code since nothing wrote to them. Purely additive.

-- 1. log_context_answers: anchor + chained-followup shape, same as
-- parent_log_answers got in 20260830000001_guided_journal_chain_flow.sql.

alter table log_context_answers add column if not exists sequence smallint not null default 0;
alter table log_context_answers add column if not exists question_text text;

update log_context_answers lca
set sequence = sub.rn
from (
  select id, row_number() over (partition by emotion_log_id order by created_at) - 1 as rn
  from log_context_answers
) sub
where lca.id = sub.id and lca.sequence <> sub.rn;

do $$
declare
  old_constraint text;
begin
  select conname into old_constraint
  from pg_constraint
  where conrelid = 'log_context_answers'::regclass
    and contype = 'u'
    and conkey = (
      select array_agg(attnum order by attnum)
      from pg_attribute
      where attrelid = 'log_context_answers'::regclass
        and attname = 'field'
    );
  if old_constraint is not null then
    execute format('alter table log_context_answers drop constraint %I', old_constraint);
  end if;
end $$;

alter table log_context_answers
  drop constraint if exists log_context_answers_entry_sequence_key;
alter table log_context_answers
  add constraint log_context_answers_entry_sequence_key unique (emotion_log_id, sequence);

comment on table log_context_answers is
  'source stays extracted|manual (check-log-context''s extraction flow); the guided-journal '
  'flow (submit-child-log-entry) always writes source=''manual'', field=''FEELING'', sequence '
  '0/1/2 = anchor/followups, same shape as parent_log_answers.';

-- 2. emotion_logs: parent-facing paraphrase column. generate-overview reads
-- ONLY this for the child signal, never journal/log_context_answers.answer.

alter table emotion_logs add column if not exists parent_facing_summary text;
comment on column emotion_logs.parent_facing_summary is
  'Written by summarize-child-log-entry — a paraphrased, value-preserving rewrite of the '
  'child''s entry. The parent must never receive the child''s raw text.';

-- 3. profiles: minimum consent gate, enforced at the RLS layer too.

alter table profiles add column if not exists child_consent_at timestamptz;
comment on column profiles.child_consent_at is
  'Set client-side on consent; emotion_logs_insert_child refuses INSERTs until set.';

create or replace function is_child() returns boolean
language sql stable
as $$
  select auth_role() = 'child'
$$;

drop policy if exists emotion_logs_insert_child on emotion_logs;
create policy emotion_logs_insert_child on emotion_logs
  for insert to authenticated
  with check (
    child_id = auth.uid()
    and family_id = auth_family_id()
    and is_child()
    and exists (
      select 1 from profiles p
      where p.id = auth.uid() and p.child_consent_at is not null
    )
  );

-- 4. Webhook: emotion_logs INSERT also fires summarize-child-log-entry,
-- alongside the existing generate-how-to-react trigger (separate function,
-- purely additive).

create or replace function notify_emotion_log_needs_summary() returns trigger
language plpgsql
as $$
begin
  perform trigger_edge_function('summarize-child-log-entry', jsonb_build_object(
    'type', 'INSERT',
    'table', 'emotion_logs',
    'record', to_jsonb(new)
  ));
  return new;
end;
$$;

create trigger on_emotion_log_needs_summary
  after insert on emotion_logs
  for each row
  when (new.context_complete = true)
  execute function notify_emotion_log_needs_summary();

-- 5. Vocabulary reality check: labels are a closed set (EmotionLabelItem,
-- 38 words) — expanded from the original 16. Associations are free-text
-- pill phrases (AssociationPickerView), never a closed set — trigger
-- narrowed to labels only, same as parent_log_entries' zero validation.

insert into emotion_label_vocabulary (value) values
  ('amazed'), ('amused'), ('angry'), ('anxious'), ('ashamed'), ('brave'),
  ('content'), ('disappointed'), ('disgusted'), ('embarrassed'),
  ('grateful'), ('guilty'), ('hopeless'), ('jealous'), ('joyful'),
  ('passionate'), ('peaceful'), ('relieved'), ('scared'), ('surprised'),
  ('confident'), ('drained'), ('satisfied')
on conflict (value) do nothing;

create or replace function validate_emotion_vocabulary() returns trigger
language plpgsql
as $$
declare
  v_invalid_labels text[];
begin
  select array_agg(l) into v_invalid_labels
  from unnest(new.labels) as l
  where l not in (select value from emotion_label_vocabulary);

  if v_invalid_labels is not null then
    raise exception 'Unknown emotion label(s): %. Add to emotion_label_vocabulary first.', v_invalid_labels;
  end if;

  return new;
end;
$$;
