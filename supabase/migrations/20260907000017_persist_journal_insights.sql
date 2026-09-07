-- Persist per-entry insights so a later view of a past journal card shows
-- the same insight that was generated at submit time, instead of always
-- falling back to the generic line.
--
-- parent_log_entries.insight_text already exists live (created outside the
-- tracked migration system at some point — same untracked-drift pattern as
-- child_profiles.communication_style) but was never actually written to:
-- generate-journal-insight accepted an entry_id specifically to persist
-- onto this column (per its client-side doc comment) but never did.
-- `if not exists` here just formalizes what's already live, safely, for
-- any environment that doesn't have it yet.
alter table parent_log_entries add column if not exists insight_text text;

-- emotion_logs has no equivalent at all yet — generate-child-log-insight
-- is new today and nothing was ever built to read it back later
-- (ChildLogDetailView hardcoded the fallback line instead).
alter table emotion_logs add column if not exists child_insight_text text;
