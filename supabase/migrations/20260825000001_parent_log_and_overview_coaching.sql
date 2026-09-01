-- be1: parent's guided journal (3 fixed/randomized main questions + up to
-- 3 followups, evaluated via cognitive-mechanism-word presence, NOT the
-- LogContextField extraction check-log-context uses — deliberately a
-- different mechanism). Mirrors emotion_logs/log_context_answers'
-- shape+RLS pattern, scoped to parent instead of child.
--
-- Also adds overviews.communication_style — new column for
-- generate-overview's refined prompt (autonomy-supportive coaching +
-- bald-on-record detection, see prompts.ts AUTONOMY_SUPPORTIVE_RULE_ID).

create table parent_log_entries (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references families (id) on delete cascade,
  parent_id uuid not null references profiles (id) on delete cascade,
  "timestamp" timestamptz not null default now(),
  valence double precision not null check (valence >= -1 and valence <= 1),
  labels text[] not null default '{}',
  associations text[] not null default '{}', -- optional by design, empty array is valid
  context_complete boolean not null default false,
  created_at timestamptz not null default now()
);
create index parent_log_entries_family_id_idx on parent_log_entries (family_id);

create table parent_log_answers (
  id uuid primary key default gen_random_uuid(),
  parent_log_entry_id uuid not null references parent_log_entries (id) on delete cascade,
  field log_context_field_type not null, -- reused enum, per user decision: same field set "from the start designed for a log/reflection app for parent too"
  source text not null check (source in ('main', 'followup')),
  question_text text not null,
  answer_text text not null,
  created_at timestamptz not null default now(),
  -- (field, source) not just (field): a followup targets the SAME field as
  -- its main question (elaborating on it, not a new field) — main+followup
  -- must be able to coexist as two rows for one field.
  unique (parent_log_entry_id, field, source)
);
comment on table parent_log_answers is
  'source = main: one of the 3 (fixed Q1 + randomized Q2/Q3) main prompts. '
  'source = followup: the one optional followup a main prompt can trigger, '
  'per evaluate-parent-log-followup''s cognitive-mechanism-word check.';

alter table parent_log_entries enable row level security;
alter table parent_log_answers enable row level security;

-- Same pattern as parent_interactions/parent_reflection_logs: parent-only,
-- both ways, family-scoped. See 20260814000002_rls_policies.sql.
create policy parent_log_entries_select_parent on parent_log_entries
  for select to authenticated
  using (family_id = auth_family_id() and is_parent());

create policy parent_log_entries_insert_parent on parent_log_entries
  for insert to authenticated
  with check (family_id = auth_family_id() and is_parent() and parent_id = auth.uid());

create policy parent_log_answers_select_parent on parent_log_answers
  for select to authenticated
  using (
    is_parent()
    and exists (
      select 1 from parent_log_entries e
      where e.id = parent_log_answers.parent_log_entry_id
        and e.family_id = auth_family_id()
    )
  );

create policy parent_log_answers_insert_parent on parent_log_answers
  for insert to authenticated
  with check (
    is_parent()
    and exists (
      select 1 from parent_log_entries e
      where e.id = parent_log_answers.parent_log_entry_id
        and e.family_id = auth_family_id()
        and e.parent_id = auth.uid()
    )
  );

-- generate-overview's refined prompt (2026-08-25): the weekly overview
-- moves from purely descriptive to including directive, actionable
-- communication coaching — supersedes the earlier "stays descriptive"
-- decision recorded in context.md (needs updating there too).
alter table overviews add column communication_style jsonb;
