-- Read back as empty even right after a re-seed — RLS was enabled on these
-- (likely by the untracked 20260901120000 migration) with no policy,
-- default-denying everyone. Open reference tables, never user data.

alter table emotion_label_vocabulary disable row level security;
alter table emotion_association_vocabulary disable row level security;
