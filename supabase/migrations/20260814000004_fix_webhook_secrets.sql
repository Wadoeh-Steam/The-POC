-- Fixes 20260814000003_webhooks.sql's approach: `alter database ... set
-- app.settings.*` requires real superuser, which Supabase's managed
-- Postgres does not grant to the `postgres` role — confirmed via a
-- permission-denied error while deploying this project 2026-08-14.
--
-- Corrected to Supabase's actual documented pattern for this exact
-- problem (a DB trigger needing a secret to call an Edge Function):
-- Supabase Vault, which the postgres role CAN write to. The functions
-- base URL isn't secret, but is stored in Vault too for consistency —
-- one mechanism, not two, and it's still project/environment-specific
-- so it still needs a one-time value set per environment (see below),
-- same deployment shape as the superseded GUC approach just via
-- `vault.create_secret` instead of `alter database ... set`.

create or replace function trigger_edge_function(function_name text, payload jsonb)
returns void
language plpgsql
as $$
declare
  v_base_url text;
  v_service_key text;
begin
  select decrypted_secret into v_base_url
    from vault.decrypted_secrets where name = 'edge_functions_base_url';
  select decrypted_secret into v_service_key
    from vault.decrypted_secrets where name = 'edge_function_service_role_key';

  if v_base_url is null or v_service_key is null then
    raise warning 'edge_functions_base_url / edge_function_service_role_key not set in Vault — % not called. See this migration''s header comment.', function_name;
    return;
  end if;

  perform net.http_post(
    url := v_base_url || '/' || function_name,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_key
    ),
    body := payload,
    timeout_milliseconds := 10000
  );
end;
$$;

-- DEPLOYMENT NOTE: run once per environment, after this migration is
-- applied (values differ between local/staging/production, same
-- reasoning as the superseded GUC approach):
--   select vault.create_secret('https://<project-ref>.supabase.co/functions/v1', 'edge_functions_base_url');
--   select vault.create_secret('<service-role-key>', 'edge_function_service_role_key');
-- Re-running create_secret with the same name errors (name is unique) —
-- use vault.update_secret(id, new_secret) to rotate instead.
