-- Child profiling onboarding (Phase 1) — standalone records the PARENT
-- fills in about each of their children, deliberately NOT tied to
-- `profiles`/the invite-accept flow: a parent should be able to describe
-- a child who has no account and may never have one. Independent of the
-- existing invite system for now (per product decision 2026-09-04) — no
-- link/dedup with a real child `profiles` row if one exists.
--
-- One family can have multiple rows ("tambah anak lain"), identified by
-- nickname. friction_areas/communication_style are the parent's own
-- free-text chip picks (Indonesian display strings stored as-is — this
-- is parent-authored descriptive data, not LLM output/vocab, so no
-- separate vocabulary table like emotion labels have).
create table child_profiles (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references families(id) on delete cascade,
  parent_id uuid not null references profiles(id) on delete cascade,
  nickname text not null,
  age_range text not null,
  living_situation text not null,
  friction_areas text[] not null default '{}',
  communication_style text[] not null default '{}',
  -- Optional open-text "apa yang pengen kamu perbaiki dari hubungan
  -- kalian?" — seeds the GROW prompt's Goal stage instead of making the
  -- LLM infer it from the first journal entry.
  goal text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table child_profiles enable row level security;

create policy child_profiles_select_parent on child_profiles
  for select to authenticated
  using (family_id = auth_family_id() and is_parent());

create policy child_profiles_insert_parent on child_profiles
  for insert to authenticated
  with check (family_id = auth_family_id() and is_parent() and parent_id = auth.uid());

create policy child_profiles_update_parent on child_profiles
  for update to authenticated
  using (family_id = auth_family_id() and is_parent() and parent_id = auth.uid())
  with check (family_id = auth_family_id() and is_parent() and parent_id = auth.uid());

create policy child_profiles_delete_parent on child_profiles
  for delete to authenticated
  using (family_id = auth_family_id() and is_parent() and parent_id = auth.uid());
