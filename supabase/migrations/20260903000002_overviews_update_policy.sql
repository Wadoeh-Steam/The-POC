-- Missing UPDATE policy on overviews.
--
-- generate-overview switched insert -> upsert (onConflict: family_id,
-- period_start) so a race/re-trigger against an existing week's row
-- overwrites instead of hard-failing on overviews_family_period_idx (the
-- unique index that enforces one overview per family per week). Postgres
-- implements upsert's conflict path as an UPDATE, and only INSERT/SELECT
-- policies existed here — with no UPDATE policy, RLS rejects that path
-- outright (42501), so the upsert would 500 every time it actually hit a
-- conflict. Found live 2026-09-03 testing the parent-only overview prompt
-- against Radit dev's existing week.

create policy overviews_update_parent on overviews
  for update to authenticated
  using (family_id = auth_family_id() and is_parent())
  with check (family_id = auth_family_id() and is_parent());
