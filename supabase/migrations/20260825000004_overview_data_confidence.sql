-- generate-overview's refined prompt now reports data_confidence (per-side
-- child/parent confidence tier, see prompts.ts buildOverviewPrompt) alongside
-- communication_style (added in 20260825000001) — same
-- "coaching format" upgrade, split into its own migration since it landed
-- slightly after that one.

alter table overviews add column data_confidence jsonb;
