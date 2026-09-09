-- Allow children to register device tokens too. Original design
-- (20260814000002_rls_policies.sql, comment: "device_tokens — parent
-- only, per ARCHITECTURE.md §5") only let a parent's own JWT insert/update
-- its own device_tokens row -- correct when only parent-facing pushes
-- (how-to-react tips, crisis alerts) existed. Now that a child should also
-- get notified when their paired parent journals, a child's own JWT needs
-- the same insert/update capability. Still fully scoped to the caller's
-- own row (profile_id = auth.uid()) either way -- just drops the
-- is_parent() restriction, doesn't loosen anything else.

drop policy if exists device_tokens_upsert_own on device_tokens;
create policy device_tokens_upsert_own on device_tokens
  for insert to authenticated
  with check (profile_id = auth.uid());

drop policy if exists device_tokens_update_own on device_tokens;
create policy device_tokens_update_own on device_tokens
  for update to authenticated
  using (profile_id = auth.uid())
  with check (profile_id = auth.uid());

comment on table device_tokens is
  'Both parent and child profiles register tokens — parent gets how-to-react/crisis/new-child-journal pushes, child gets new-parent-journal pushes.';
