-- child_profiles isn't defined in any migration in this repo (created
-- outside the tracked migration system, like 20260901120000 earlier) — so
-- this is a targeted fix, not a full table migration.
--
-- ChildProfilingView moved communication_style from multi-select ([String])
-- to single-select (String) client-side, but the column is still text[] —
-- every save now fails with "malformed array literal" since a plain string
-- doesn't parse as an array literal. array_to_string preserves any
-- existing multi-value rows as a comma-joined string rather than dropping data.

alter table child_profiles
  alter column communication_style type text
  using array_to_string(communication_style, ', ');
