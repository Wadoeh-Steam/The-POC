-- Multi-child journaling attribution (child_profiling brief, 2026-09-07).
--
-- generate-journal-insight now matches an entry's free text against the
-- family's child_profiles roster (nickname + friction_areas/communication_
-- style) in the same LLM call that generates the insight, and returns
-- which child (if any, confidently) the entry was about. NULL means
-- "general/no confident match" — never a forced guess (see
-- buildJournalInsightPrompt's doc comment, _shared/prompts.ts). The
-- journal-preview attribution chip lets the parent correct this after the
-- fact; that correction is a plain UPDATE from the client's own JWT, which
-- the existing parent_log_entries_update_own policy (20260825000003)
-- already covers — RLS is row-scoped, not column-scoped, so no new policy
-- is needed just to allow writing this one column.
--
-- on delete set null (not cascade): deleting a child_profiles row should
-- never delete the parent's own journal entries — it just un-attributes
-- them back to general.
alter table parent_log_entries
  add column child_profile_id uuid references child_profiles(id) on delete set null;
