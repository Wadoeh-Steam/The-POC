-- Database webhooks — as code, not dashboard clicks. A webhook configured
-- through Supabase Studio isn't in version control and won't show up in
-- code review; every engineer touching this project needs to see these
-- triggers by reading the migrations, not by clicking through the dashboard.
--
-- Depends on the `supabase_functions` schema + `pg_net`, both provisioned
-- by default on Supabase-hosted projects and via `supabase start` locally.
--
-- DEPLOYMENT NOTE: two settings below are project-specific and differ
-- between local/staging/production — set both once per environment
-- (e.g. via your deploy pipeline, right after `supabase db push`):
--   alter database postgres set app.settings.functions_url = 'https://<project-ref>.supabase.co/functions/v1';
--   alter database postgres set app.settings.service_role_key = '<service role key>';
-- Neither is resolved to a literal here on purpose — either one would be
-- wrong for at least two of your three environments. The service role key
-- specifically: treat it with the same care as any other secret — it's
-- going into Postgres config, not source control, but it's still the key
-- that bypasses RLS entirely.

create or replace function trigger_edge_function(function_name text, payload jsonb)
returns void
language plpgsql
as $$
declare
  v_base_url text;
begin
  v_base_url := current_setting('app.settings.functions_url', true);
  if v_base_url is null then
    raise warning 'app.settings.functions_url not set — % not called. See migration comment.', function_name;
    return;
  end if;

  perform net.http_post(
    url := v_base_url || '/' || function_name,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key', true)
    ),
    body := payload,
    timeout_milliseconds := 10000
  );
end;
$$;

-- ============================================================================
-- emotion_logs INSERT, only once context_complete = true — fires
-- generate-how-to-react (ARCHITECTURE.md §4). The WHEN clause is the actual
-- gate; the function itself also re-checks llm_mode before doing anything
-- (§2a — no-ops in on_device mode), belt-and-suspenders since a trigger
-- misconfiguration shouldn't be the only thing standing between "child
-- picked on_device" and "we called Gemini anyway".
-- ============================================================================

create or replace function notify_emotion_log_context_complete() returns trigger
language plpgsql
as $$
begin
  perform trigger_edge_function('generate-how-to-react', jsonb_build_object(
    'type', 'INSERT',
    'table', 'emotion_logs',
    'record', to_jsonb(new)
  ));
  return new;
end;
$$;

create trigger on_emotion_log_context_complete
  after insert on emotion_logs
  for each row
  when (new.context_complete = true)
  execute function notify_emotion_log_context_complete();

-- ============================================================================
-- how_to_react_tips INSERT — fires send-how-to-react-push (mode-agnostic,
-- §2a: fires whether the row came from generate-how-to-react or a client
-- writing it directly in on_device mode).
-- ============================================================================

create or replace function notify_how_to_react_tip_created() returns trigger
language plpgsql
as $$
begin
  perform trigger_edge_function('send-how-to-react-push', jsonb_build_object(
    'type', 'INSERT',
    'table', 'how_to_react_tips',
    'record', to_jsonb(new)
  ));
  return new;
end;
$$;

create trigger on_how_to_react_tip_created
  after insert on how_to_react_tips
  for each row
  execute function notify_how_to_react_tip_created();

-- ============================================================================
-- crisis_events INSERT — fires send-crisis-alert-push (§2b). Always fires,
-- mode-agnostic, highest priority of the three webhooks here.
-- ============================================================================

create or replace function notify_crisis_event_created() returns trigger
language plpgsql
as $$
begin
  perform trigger_edge_function('send-crisis-alert-push', jsonb_build_object(
    'type', 'INSERT',
    'table', 'crisis_events',
    'record', to_jsonb(new)
  ));
  return new;
end;
$$;

create trigger on_crisis_event_created
  after insert on crisis_events
  for each row
  execute function notify_crisis_event_created();
