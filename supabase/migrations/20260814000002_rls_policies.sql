-- Row Level Security for EmotionPOC.
-- Source of truth for design intent: ../../ARCHITECTURE.md §3 "RLS policy
-- shape" + "Child is write-only for LLM outputs", and ADR-0005.
--
-- Core invariant this file enforces: family_id scoping alone is NOT
-- sufficient. `overviews`, `reflections`, `how_to_react_tips`,
-- `crisis_events`, `parent_interactions`, `parent_reflection_logs` are
-- role-restricted to `parent` — a child sharing the same family_id must
-- NOT be able to SELECT these. This was a real gap caught during
-- architecture review (see ADR-0005) — don't relax it back to family-only
-- scoping.

-- ============================================================================
-- Helper functions
-- ============================================================================

-- STABLE, not SECURITY DEFINER — deliberately still subject to RLS. This
-- resolves correctly (not infinite recursion) because every table below
-- has an explicit "own row" or family-scoped policy that lets a user
-- read at least their own profiles row, which is all these functions need.
create or replace function auth_family_id() returns uuid
language sql stable
as $$
  select family_id from profiles where id = auth.uid()
$$;

create or replace function auth_role() returns profile_role
language sql stable
as $$
  select role from profiles where id = auth.uid()
$$;

create or replace function is_parent() returns boolean
language sql stable
as $$
  select auth_role() = 'parent'
$$;

-- ============================================================================
-- Enable RLS everywhere
-- ============================================================================

alter table families enable row level security;
alter table profiles enable row level security;
alter table device_tokens enable row level security;
alter table invites enable row level security;
alter table emotion_logs enable row level security;
alter table crisis_events enable row level security;
alter table log_context_answers enable row level security;
alter table parent_interactions enable row level security;
alter table parent_reflection_logs enable row level security;
alter table overviews enable row level security;
alter table reflections enable row level security;
alter table how_to_react_tips enable row level security;

-- ============================================================================
-- families
-- ============================================================================

-- Deliberately no direct-INSERT policy on families either — same reasoning
-- as profiles below. create_family() is SECURITY DEFINER and creates both
-- rows itself; a raw client INSERT here isn't needed and would just be
-- unused attack surface.

create policy families_select_own on families
  for select to authenticated
  using (id = auth_family_id());

-- ============================================================================
-- profiles
-- ============================================================================

-- Own row always readable (this is also what makes auth_family_id()/
-- auth_role() resolve without recursion for every other policy).
create policy profiles_select_own on profiles
  for select to authenticated
  using (id = auth.uid());

-- Family members can see each other's basic profile (display_name etc.) —
-- this is not sensitive LLM output, unlike the tables restricted below.
create policy profiles_select_family on profiles
  for select to authenticated
  using (family_id = auth_family_id());

-- Deliberately NO direct-INSERT policy on profiles. If there were one
-- scoped only to `id = auth.uid()`, any authenticated user could insert
-- themselves as role='parent' into an arbitrary family_id, bypassing the
-- invite flow entirely (caught during review — don't re-add this policy
-- without re-solving that). The only two ways a profiles row gets created:
--   - create_family() below (SECURITY DEFINER, always role='parent',
--     always a brand-new family — no existing-family join possible)
--   - accept-family-invite Edge Function (service role, validates a real
--     invite token first — see ARCHITECTURE.md §3b)

create policy profiles_update_own on profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- Allows the user to update their own row (e.g. llm_mode, display_name)
-- but not escalate by changing their own family_id or role — that would
-- be an invite-flow bypass, same risk as the removed INSERT policy above.
create or replace function prevent_profile_privilege_escalation() returns trigger
language plpgsql
as $$
begin
  if new.family_id is distinct from old.family_id or new.role is distinct from old.role then
    raise exception 'Cannot change family_id or role via UPDATE — use the invite flow instead.';
  end if;
  return new;
end;
$$;

create trigger profiles_prevent_privilege_escalation
  before update on profiles
  for each row execute function prevent_profile_privilege_escalation();

-- ============================================================================
-- device_tokens — parent only, per ARCHITECTURE.md §5
-- ============================================================================

create policy device_tokens_select_own on device_tokens
  for select to authenticated
  using (profile_id = auth.uid());

create policy device_tokens_upsert_own on device_tokens
  for insert to authenticated
  with check (profile_id = auth.uid() and is_parent());

create policy device_tokens_update_own on device_tokens
  for update to authenticated
  using (profile_id = auth.uid() and is_parent())
  with check (profile_id = auth.uid() and is_parent());

-- ============================================================================
-- invites — parent can SELECT their own family's invites. Deliberately no
-- INSERT/UPDATE/DELETE policy at all: creating one needs a securely
-- server-generated token (not a client-supplied one — no guarantee a
-- client uses a strong RNG for something this security-sensitive) via
-- send-family-invite, and accepting one only happens through
-- accept-family-invite. Both are service-role Edge Functions; default-deny
-- on the table itself is correct here, not a gap.
-- ============================================================================

create policy invites_select_parent on invites
  for select to authenticated
  using (family_id = auth_family_id() and is_parent());

-- ============================================================================
-- emotion_logs — family-scoped SELECT both roles, child-only INSERT.
-- No UPDATE/DELETE policy: entries are append-only in this design.
-- ============================================================================

create policy emotion_logs_select_family on emotion_logs
  for select to authenticated
  using (family_id = auth_family_id());

create policy emotion_logs_insert_child on emotion_logs
  for insert to authenticated
  with check (
    child_id = auth.uid()
    and family_id = auth_family_id()
    and auth_role() = 'child'
  );

-- ============================================================================
-- crisis_events — parent-only SELECT (ADR-0005), child can INSERT for
-- their own logs (client-side keyword pre-filter, §2b — must work without
-- waiting on a network round trip, so this has to be a direct client write).
-- ============================================================================

create policy crisis_events_select_parent on crisis_events
  for select to authenticated
  using (
    is_parent()
    and exists (
      select 1 from emotion_logs el
      where el.id = crisis_events.emotion_log_id
        and el.family_id = auth_family_id()
    )
  );

create policy crisis_events_insert_child on crisis_events
  for insert to authenticated
  with check (
    exists (
      select 1 from emotion_logs el
      where el.id = crisis_events.emotion_log_id
        and el.child_id = auth.uid()
    )
  );

-- ============================================================================
-- log_context_answers — family-scoped SELECT both roles (needed for LLM
-- prompts and for the child to see their own answers), child-only INSERT.
-- ============================================================================

create policy log_context_answers_select_family on log_context_answers
  for select to authenticated
  using (
    exists (
      select 1 from emotion_logs el
      where el.id = log_context_answers.emotion_log_id
        and el.family_id = auth_family_id()
    )
  );

create policy log_context_answers_insert_child on log_context_answers
  for insert to authenticated
  with check (
    exists (
      select 1 from emotion_logs el
      where el.id = log_context_answers.emotion_log_id
        and el.child_id = auth.uid()
    )
  );

-- ============================================================================
-- parent_interactions / parent_reflection_logs — parent-only, both ways.
-- This is the parent's own material, not something the child reads or
-- writes (ARCHITECTURE.md §3).
-- ============================================================================

create policy parent_interactions_select_parent on parent_interactions
  for select to authenticated
  using (family_id = auth_family_id() and is_parent());

create policy parent_interactions_insert_parent on parent_interactions
  for insert to authenticated
  with check (family_id = auth_family_id() and is_parent() and parent_id = auth.uid());

create policy parent_reflection_logs_select_parent on parent_reflection_logs
  for select to authenticated
  using (family_id = auth_family_id() and is_parent());

create policy parent_reflection_logs_insert_parent on parent_reflection_logs
  for insert to authenticated
  with check (family_id = auth_family_id() and is_parent() and parent_id = auth.uid());

-- ============================================================================
-- overviews / reflections — parent-only SELECT. INSERT policy exists only
-- for on_device mode (§2a): the parent's own client writes directly when
-- skipping the Edge Function. In server mode, the Edge Function uses the
-- service-role key and bypasses RLS entirely — this policy doesn't block
-- that path, it only enables the client-direct path.
-- ============================================================================

create policy overviews_select_parent on overviews
  for select to authenticated
  using (family_id = auth_family_id() and is_parent());

create policy overviews_insert_parent_on_device on overviews
  for insert to authenticated
  with check (family_id = auth_family_id() and is_parent());

create policy reflections_select_parent on reflections
  for select to authenticated
  using (family_id = auth_family_id() and is_parent());

create policy reflections_insert_parent_on_device on reflections
  for insert to authenticated
  with check (family_id = auth_family_id() and is_parent());

-- ============================================================================
-- how_to_react_tips — parent-only SELECT (ADR-0005), child-only INSERT for
-- on_device mode (their device computes the tip, §2a). Write-only for the
-- child: this INSERT policy exists without any matching child SELECT
-- policy, so they can write but never read it back.
-- ============================================================================

create policy how_to_react_tips_select_parent on how_to_react_tips
  for select to authenticated
  using (
    is_parent()
    and exists (
      select 1 from emotion_logs el
      where el.id = how_to_react_tips.emotion_log_id
        and el.family_id = auth_family_id()
    )
  );

create policy how_to_react_tips_insert_child_on_device on how_to_react_tips
  for insert to authenticated
  with check (
    exists (
      select 1 from emotion_logs el
      where el.id = how_to_react_tips.emotion_log_id
        and el.child_id = auth.uid()
    )
  );

-- ============================================================================
-- create_family() — the ONLY way a parent profile gets created (there is
-- no direct-INSERT RLS policy on profiles, see the comment above
-- profiles_update_own). SECURITY DEFINER so it can insert into profiles
-- despite that — safe specifically because the function body is fully
-- controlled: role is hardcoded to 'parent', family_id always comes from
-- a family this same call just created (no path to join an existing
-- family), and the profile id is always auth.uid() (unaffected by
-- SECURITY DEFINER — that only elevates table/RLS permissions, not what
-- auth.uid() resolves to).
-- ============================================================================

create or replace function create_family(
  p_name text,
  p_timezone text default 'Asia/Jakarta',
  p_display_name text default 'Parent'
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_family_id uuid;
begin
  insert into families (name, timezone) values (p_name, p_timezone)
  returning id into v_family_id;

  insert into profiles (id, family_id, role, display_name)
  values (auth.uid(), v_family_id, 'parent', p_display_name);

  return v_family_id;
end;
$$;
