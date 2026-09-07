-- emotion_label_vocabulary/emotion_association_vocabulary read back as
-- empty via PostgREST even immediately after a successful re-seed insert
-- (20260907000002) — consistent with RLS having been enabled on these
-- tables (by the untracked 20260901120000 migration, repaired away in
-- tracking but never actually undone in schema) with no SELECT policy,
-- default-denying everyone including validate_emotion_vocabulary()'s own
-- trigger, which runs as the calling role, not SECURITY DEFINER. These are
-- open reference/lookup tables by design (ARCHITECTURE.md §3 — "expand
-- later by referencing... a plain INSERT" implies no access restriction),
-- never contain user data, so RLS is not appropriate here at all.

alter table emotion_label_vocabulary disable row level security;
alter table emotion_association_vocabulary disable row level security;
