-- generate-journal-insight's "kesimpulan + validasi emosi" was client-side
-- only (nothing persisted) since it was added 2026-08-30 — fine while the
-- only place it was shown was JournalPreviewView, right after submit. But
-- DailyLogListView/DashboardView (calendar/history flow) needs to show the
-- SAME insight again when a parent taps back into a past log entry, and it
-- has no way to regenerate it (the in-memory PromptStepViewModel from that
-- submit is long gone by then). Persist it once, at generation time, keyed
-- to the entry it was generated for.

alter table parent_log_entries add column insight_text text;
