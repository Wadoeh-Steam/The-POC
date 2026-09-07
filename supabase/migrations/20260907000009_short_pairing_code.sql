-- Pairing moves from a UUID token + Universal Link to a short human-typeable
-- code (e.g. "BBK-KGP", stored without the dash). invites.token keeps its
-- name/type (text, unique) — only the generation format changes.
--
-- Brute-force guard: a 6-char code has a far smaller keyspace than a UUID,
-- and most guesses won't match any real invite row at all, so tracking
-- failed attempts per-invite (which only exists for real codes) wouldn't
-- catch someone trying random codes. Tracked per calling user instead —
-- accept-family-invite always requires a real authenticated caller first.

create table invite_redemption_attempts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  failed_attempts integer not null default 0,
  window_started_at timestamptz not null default now()
);
comment on table invite_redemption_attempts is
  'accept-family-invite rejects once failed_attempts hits the cap within window_started_at''s window.';

-- RLS enabled with NO policies (default-deny for every role) — only
-- accept-family-invite's service-role admin client touches this table.
-- Without this, a client could reset their own counter directly via
-- PostgREST and bypass the rate limit entirely.
alter table invite_redemption_attempts enable row level security;
