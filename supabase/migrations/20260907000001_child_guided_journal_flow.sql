-- Child guided-journal flow: the child side of the mirrored `parent_log_entries`
-- flow, writing to the ORIGINAL emotion_logs/log_context_answers tables
-- (ARCHITECTURE.md §3, §3a) instead of a new table pair — generate-overview
-- already queries these two as the "child signal" half of the bidirectional
-- overview prompt (see generate-overview/index.ts), it's just been dead
-- code since nothing wrote to them. This migration only ADDS columns/
-- policies/triggers — nothing here alters or removes anything the parent
-- flow, generate-how-to-react, or check-log-context currently depend on.
--
-- Three additive changes:
--   1. log_context_answers gets the same anchor+chained-followup shape
--      parent_log_answers got in 20260830000001_guided_journal_chain_flow.sql
--      (sequence + question_text columns, unique-per-sequence instead of
--      unique-per-field) — needed because the child flow reuses the exact
--      same 1-anchor-plus-up-to-2-followups mechanism, not the original
--      6-field extraction model check-log-context still serves.
--   2. emotion_logs gets `parent_facing_summary` — a paraphrased,
--      value-preserving rewrite of the child's entry, written by the new
--      summarize-child-log-entry function (webhook-triggered, mirrors
--      generate-how-to-react's wiring). generate-overview is updated
--      separately to read ONLY this column for the child signal, never
--      `journal`/log_context_answers.answer verbatim — the parent must
--      never receive the child's raw text (product decision, not a
--      technical default).
--   3. profiles gets `child_consent_at` — minimum-viable UU PDP consent
--      gate. emotion_logs' child-insert RLS policy is tightened to require
--      it, so consent is enforced at the data layer, not just by a client
--      screen that could be skipped by calling the API directly.

-- ============================================================================
-- 1. log_context_answers: anchor + chained-followup shape
-- ============================================================================

alter table log_context_answers add column if not exists sequence smallint not null default 0;
alter table log_context_answers add column if not exists question_text text;

-- Empty in production today (nothing has ever written to emotion_logs client-
-- side — see context.md), but backfill defensively the same way the parent
-- migration did, in case any manual/test rows exist.
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
  'source stays extracted|manual (the enum check-log-context''s extraction flow still uses); '
  'the child guided-journal flow (submit-child-log-entry) always writes source=''manual'', '
  'field=''FEELING'' for every row (sequence 0 = anchor, 1/2 = chained followups), same '
  'shape as parent_log_answers. question_text is null for rows check-log-context''s '
  'extraction flow produces (it never asks a literal question), populated for the '
  'guided-journal flow''s rows.';

-- ============================================================================
-- 2. emotion_logs: parent-facing paraphrase column
-- ============================================================================

alter table emotion_logs add column if not exists parent_facing_summary text;
comment on column emotion_logs.parent_facing_summary is
  'Written by summarize-child-log-entry (webhook on INSERT, context_complete=true) — a '
  'paraphrased rewrite of the child''s journal/answers that preserves meaning without '
  'passing the raw text through. generate-overview reads ONLY this column for the child '
  'signal, never journal/log_context_answers.answer directly — parent-facing product '
  'boundary, not just a technical default.';

-- ============================================================================
-- 3. profiles: minimum consent gate
-- ============================================================================

alter table profiles add column if not exists child_consent_at timestamptz;
comment on column profiles.child_consent_at is
  'Set once, client-side, when a child profile completes the minimum consent screen '
  '(UU PDP explicit-consent requirement — sensitive health + children''s data). Null means '
  'not yet consented; emotion_logs_insert_child below refuses INSERTs until this is set. '
  'Irrelevant for parent profiles (always null).';

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

-- ============================================================================
-- 4. Webhook: emotion_logs INSERT (context_complete = true) also fires
-- summarize-child-log-entry, alongside the existing generate-how-to-react
-- trigger from 20260814000003_webhooks.sql — a separate trigger function so
-- this is purely additive, no edit to the existing one.
-- ============================================================================

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

-- ============================================================================
-- 5. Vocabulary reality check, found while wiring the actual client flow:
--
-- Labels: EmotionApp's LabelPickerView sends EmotionLabelItem.rawValue (the
-- client enum is an explicit, documented 1:1 mirror of
-- select-parent-log-questions' EMOTION_LABEL_CLUSTERS dictionary keys) — a
-- genuinely closed set, just bigger than the 16 words seeded on
-- 2026-08-14. Expanding it here (plain INSERT, per the original design
-- note in ARCHITECTURE.md §3 — "expand later by referencing... don't
-- hard-code a guessed full list now") to the full 38-word set so real
-- label picks stop failing the vocabulary trigger.
--
-- Associations: AssociationPickerView (confirmed by reading the Swift,
-- 2026-09-07) sends free-text Indonesian pill phrases from
-- ImpactBulletsView (e.g. "Tidur Cukup", "Dukungan Keluarga"), NOT the
-- AssociationItem enum (dead/unused code) and NOT a closed HealthKit-style
-- set at all — same open-ended mechanism parent_log_entries.associations
-- already accepts with zero validation. Enforcing emotion_association_vocabulary
-- against that would reject nearly every real submission, so this trigger
-- is narrowed to labels only — associations become as unvalidated here as
-- they already are on parent_log_entries, not a new looser standard.
-- ============================================================================

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

  -- associations intentionally unchecked — see comment above this section.
  return new;
end;
$$;
