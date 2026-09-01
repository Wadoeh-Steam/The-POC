-- Fix infinite recursion in profiles RLS.
--
-- auth_family_id()/auth_role() were STABLE but NOT security definer, while
-- profiles has a policy (profiles_select_family, 20260814000002) that
-- itself calls auth_family_id() — evaluating that policy re-triggers the
-- function, which re-triggers the policy, etc. The original migration's
-- comment ("resolves correctly because every table has an explicit own
-- row policy") assumed Postgres short-circuits OR'd permissive policies
-- left-to-right; it doesn't guarantee that.
--
-- Discovered live (2026-08-25) testing be1 end-to-end against a real user
-- JWT: any direct SELECT against `profiles` returned "stack depth limit
-- exceeded" (Postgres error 54001). Since nearly every RLS policy in this
-- schema — and every Edge Function that checks callerProfile — depends on
-- auth_family_id()/auth_role()/is_parent(), this blocked the whole app,
-- not just be1.
--
-- Fix: SECURITY DEFINER on the two functions that query `profiles`
-- directly, so their internal lookup bypasses RLS instead of re-entering
-- it. search_path locked to `public` per Postgres's SECURITY DEFINER
-- hardening guidance (prevents search_path hijacking). is_parent() is
-- untouched — it only calls auth_role(), no direct table access, so it
-- was never itself recursive.

create or replace function auth_family_id() returns uuid
language sql stable security definer
set search_path = public
as $$
  select family_id from profiles where id = auth.uid()
$$;

create or replace function auth_role() returns profile_role
language sql stable security definer
set search_path = public
as $$
  select role from profiles where id = auth.uid()
$$;
