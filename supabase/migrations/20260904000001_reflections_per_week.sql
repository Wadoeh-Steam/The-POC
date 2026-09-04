-- Reflections ("Lihat Saran") were whole-history and cached forever once
-- generated — no way to ever see fresh advice as new weeks of journaling
-- came in. Rescoped to per-week, same shape as `overviews`: one row per
-- family per week, upserted on regenerate, exact-matched by the client
-- before falling back to a real generate call.

alter table reflections add column period_start timestamptz;
alter table reflections add column period_end timestamptz;

create unique index reflections_family_period_idx
  on reflections(family_id, period_start);

-- Missing UPDATE policy — same gap as overviews (see
-- 20260903000002_overviews_update_policy.sql): upsert's conflict path is
-- an UPDATE under the hood, and only INSERT/SELECT policies existed here.
create policy reflections_update_parent on reflections
  for update to authenticated
  using (family_id = auth_family_id() and is_parent())
  with check (family_id = auth_family_id() and is_parent());
