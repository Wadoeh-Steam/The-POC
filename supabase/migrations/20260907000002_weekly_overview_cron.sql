-- Weekly overview generation moved from "the moment a parent opens
-- Ringkasan" to a scheduled Friday-night batch (product decision
-- 2026-09-07) — a fresh, often data-thin card appearing the instant a new
-- week starts defeats what "weekly" is supposed to mean. See
-- generate-weekly-overviews-batch's doc comment and RingkasanViewModel.
-- swift's weeklyOverviewCutoff (the client-side mirror, used only as a
-- missed-cron safety net there).
--
-- pg_cron/pg_net are enabled by default on Supabase-hosted projects, but
-- declared explicitly here for local (`supabase start`) parity.
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Reuses the Vault-backed trigger_edge_function() helper already set up
-- for DB webhooks (20260814000004_fix_webhook_secrets.sql) — same
-- edge_functions_base_url/edge_function_service_role_key secrets, no new
-- Vault setup needed. cron.schedule with an existing job name updates it
-- in place, so this migration is safe to re-apply.
select cron.schedule(
  'generate-weekly-overviews-friday-night',
  '0 12 * * 5', -- Friday 12:00 UTC = Friday 19:00 WIB (WIB is UTC+7, no DST)
  $$ select trigger_edge_function('generate-weekly-overviews-batch', '{}'::jsonb); $$
);
