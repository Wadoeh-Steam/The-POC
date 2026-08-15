-- Initial schema for EmotionPOC.
-- Source of truth for design intent: ../../ARCHITECTURE.md §3 (data model),
-- §2b (guardrails), §3a (guided journaling), §3b (pairing).
-- Decision rationale: ../../docs/adr/ (0001, 0003, 0005, 0006, 0008).
--
-- This migration is the mechanical translation of ARCHITECTURE.md §3 into
-- real DDL. If a table/column here diverges from that doc, the doc is stale
-- — update it, don't let this file become the only source of truth silently.

-- ============================================================================
-- Enums
-- ============================================================================

create type profile_role as enum ('parent', 'child');
create type llm_mode_type as enum ('server', 'on_device');
create type emotion_kind as enum ('dailyMood', 'momentaryEmotion');
create type invite_status_type as enum ('pending', 'accepted', 'expired');
create type log_context_field_type as enum (
  'FEELING', 'TRIGGER', 'PERCEIVED_CAUSE', 'PRIOR_EFFORT', 'FUTURE_PLAN', 'EXPECTED_OUTCOME'
);
create type context_answer_source_type as enum ('extracted', 'manual');
create type crisis_detection_method_type as enum ('keyword', 'llm');

-- MVP label/association vocabulary — copied from HealthKit's State of Mind
-- string values (see ADR-0003), NOT the HealthKit framework. This is
-- deliberately the *base set from the dummy dataset*, not Apple's full
-- published list (ARCHITECTURE.md §3) — expand later with a plain INSERT
-- into these tables (enforced by trigger below, not a CHECK constraint),
-- don't hardcode a guessed-complete list now.
create table emotion_label_vocabulary (
  value text primary key
);
insert into emotion_label_vocabulary (value) values
  ('calm'), ('hopeful'), ('frustrated'), ('annoyed'), ('lonely'), ('sad'),
  ('worried'), ('proud'), ('excited'), ('stressed'), ('overwhelmed'),
  ('irritated'), ('amused'), ('happy'), ('discouraged'), ('indifferent');

create table emotion_association_vocabulary (
  value text primary key
);
insert into emotion_association_vocabulary (value) values
  ('family'), ('education'), ('friends'), ('tasks');

-- ============================================================================
-- Core tables
-- ============================================================================

create table families (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  timezone text not null default 'Asia/Jakarta',
  created_at timestamptz not null default now()
);
comment on table families is
  'Our own construct — no Apple Family Sharing involved. See ADR-0004.';

create table profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  family_id uuid not null references families (id) on delete cascade,
  role profile_role not null,
  display_name text not null,
  age integer,
  relationship text,
  llm_mode llm_mode_type not null default 'server',
  created_at timestamptz not null default now()
);
comment on column profiles.llm_mode is
  'Per-profile, not per-family — each person sets their own. See ADR-0002.';
create index profiles_family_id_idx on profiles (family_id);

create table device_tokens (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles (id) on delete cascade,
  apns_token text not null,
  created_at timestamptz not null default now(),
  unique (profile_id, apns_token)
);
comment on table device_tokens is
  'Only parent profiles register tokens in the current design — child role never needs push.';

create table invites (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references families (id) on delete cascade,
  invited_email text not null,
  invited_role profile_role not null default 'child',
  invited_by uuid not null references profiles (id) on delete cascade,
  token text not null unique,
  status invite_status_type not null default 'pending',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
comment on table invites is
  'Parent→child pairing via email invite, not Apple Family Sharing. See ADR-0004. '
  'Token expiry duration / resend-revoke policy: open item, ARCHITECTURE.md §7.';
create index invites_family_id_idx on invites (family_id);
create index invites_token_idx on invites (token);

create table emotion_logs (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references profiles (id) on delete cascade,
  family_id uuid not null references families (id) on delete cascade,
  "timestamp" timestamptz not null default now(),
  source text not null default 'app',
  kind emotion_kind not null,
  valence double precision not null check (valence >= -1 and valence <= 1),
  labels text[] not null default '{}',
  associations text[] not null default '{}',
  journal text,
  -- Placeholder thresholds — NOT finalized, see ARCHITECTURE.md §3 and §7.
  -- Whoever finalizes the real buckets: replace this expression, don't add
  -- a second classification column elsewhere.
  valence_classification text generated always as (
    case
      when valence >= 0.5 then 'positive'
      when valence >= 0.15 then 'slightlyPositive'
      when valence > -0.15 then 'neutral'
      when valence > -0.5 then 'slightlyNegative'
      else 'negative'
    end
  ) stored,
  -- true once every log_context_field the LLM couldn't extract has been
  -- answered via follow-up (§3a). The happy path only ever INSERTs once
  -- this is already true; the sole exception is a crisis-flagged entry
  -- (§2b), saved immediately as incomplete. See the "Crisis-flagged
  -- entries save early" row in ARCHITECTURE.md §6.
  context_complete boolean not null default false,
  created_at timestamptz not null default now()
);
create index emotion_logs_child_id_idx on emotion_logs (child_id);
create index emotion_logs_family_id_idx on emotion_logs (family_id);
create index emotion_logs_context_complete_idx on emotion_logs (context_complete) where not context_complete;

-- Postgres CHECK constraints can't contain subqueries, so vocabulary
-- membership (against emotion_label_vocabulary / emotion_association_vocabulary
-- above) is enforced by trigger instead — this also means expanding the
-- vocabulary later is just an INSERT into those tables, no ALTER TABLE
-- needed on emotion_logs itself.
create or replace function validate_emotion_vocabulary() returns trigger
language plpgsql
as $$
declare
  v_invalid_labels text[];
  v_invalid_associations text[];
begin
  select array_agg(l) into v_invalid_labels
  from unnest(new.labels) as l
  where l not in (select value from emotion_label_vocabulary);

  if v_invalid_labels is not null then
    raise exception 'Unknown emotion label(s): %. Add to emotion_label_vocabulary first.', v_invalid_labels;
  end if;

  select array_agg(a) into v_invalid_associations
  from unnest(new.associations) as a
  where a not in (select value from emotion_association_vocabulary);

  if v_invalid_associations is not null then
    raise exception 'Unknown emotion association(s): %. Add to emotion_association_vocabulary first.', v_invalid_associations;
  end if;

  return new;
end;
$$;

create trigger emotion_logs_validate_vocabulary
  before insert or update on emotion_logs
  for each row execute function validate_emotion_vocabulary();

create table crisis_events (
  id uuid primary key default gen_random_uuid(),
  emotion_log_id uuid not null references emotion_logs (id) on delete cascade,
  detected_at timestamptz not null default now(),
  detection_method crisis_detection_method_type not null,
  acknowledged_by_parent boolean not null default false,
  created_at timestamptz not null default now()
);
comment on table crisis_events is
  'Guardrail audit trail, see ARCHITECTURE.md §2b and ADR-0006. '
  'emotion_log_id is NOT NULL by design — crisis detection forces an early, '
  'partial emotion_logs save specifically so this FK always has something valid to point to.';
create index crisis_events_emotion_log_id_idx on crisis_events (emotion_log_id);

create table log_context_answers (
  id uuid primary key default gen_random_uuid(),
  emotion_log_id uuid not null references emotion_logs (id) on delete cascade,
  field log_context_field_type not null,
  answer text not null,
  source context_answer_source_type not null,
  created_at timestamptz not null default now(),
  unique (emotion_log_id, field)
);
create index log_context_answers_emotion_log_id_idx on log_context_answers (emotion_log_id);

create table parent_interactions (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid not null references profiles (id) on delete cascade,
  family_id uuid not null references families (id) on delete cascade,
  "timestamp" timestamptz not null default now(),
  topic text not null,
  interaction text not null,
  parent_emotion text,
  created_at timestamptz not null default now()
);
create index parent_interactions_family_id_idx on parent_interactions (family_id);

create table parent_reflection_logs (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid not null references profiles (id) on delete cascade,
  family_id uuid not null references families (id) on delete cascade,
  "timestamp" timestamptz not null default now(),
  emotion text not null,
  note text,
  created_at timestamptz not null default now()
);
create index parent_reflection_logs_family_id_idx on parent_reflection_logs (family_id);

create table overviews (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references families (id) on delete cascade,
  generated_at timestamptz not null default now(),
  headline text not null,
  summary text not null,
  patterns jsonb not null default '[]',
  relationship_signal jsonb not null,
  key_insight text not null,
  raw_response jsonb,
  created_at timestamptz not null default now()
);
comment on table overviews is 'Cache — avoid regenerating on every parent open.';
create index overviews_family_id_idx on overviews (family_id, generated_at desc);

create table reflections (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references families (id) on delete cascade,
  generated_at timestamptz not null default now(),
  recommendations jsonb not null default '[]',
  raw_response jsonb,
  created_at timestamptz not null default now()
);
create index reflections_family_id_idx on reflections (family_id, generated_at desc);

create table how_to_react_tips (
  id uuid primary key default gen_random_uuid(),
  emotion_log_id uuid not null references emotion_logs (id) on delete cascade,
  generated_at timestamptz not null default now(),
  tip text not null,
  raw_response jsonb,
  created_at timestamptz not null default now()
);
create index how_to_react_tips_emotion_log_id_idx on how_to_react_tips (emotion_log_id);
