# ADR-0005: Child is feed-only — no read access to LLM outputs

**Status:** Accepted
**Date:** 2026-08-14
**Deciders:** radityaaydin

## Context

The product statement is about helping *parents* understand their child's perspective. The user clarified explicitly: the child side can only feed data (submit emotion logs) — reflections and how-to-react tips are for the parent alone, never shown to the child.

This surfaced a real gap during initial design: the original RLS policy shape only scoped `SELECT` by `family_id`, which — since parent and child share the same `family_id` — would have let the child read `overviews`, `reflections`, and `how_to_react_tips` too. Family-scoping alone wasn't sufficient.

## Decision

RLS on `overviews`, `reflections`, `how_to_react_tips`, `crisis_events`, `parent_interactions`, and `parent_reflection_logs` is restricted to `role = 'parent'` within the family, not just `family_id` match. The child role can still `INSERT` into `how_to_react_tips`/`crisis_events` in `on_device` mode (their device computes these), but that's write-only — no matching `SELECT` grant. The iOS app mirrors this at the UI layer too: no reflection/overview/tip screen exists anywhere in the child-side navigation.

## Options Considered

### Option A: Role-restricted SELECT (chosen)
**Pros:** Matches the actual product requirement; enforced at the data layer, not just by omitting UI — a client bug or a future engineer adding a screen can't accidentally leak this data to the child.
**Cons:** More RLS policies to write and reason about than a flat family-scope rule.

### Option B: Family-scoped SELECT only (original draft, superseded)
**Pros:** Simpler RLS.
**Cons:** Actually wrong — lets the child read parent-only content, caught during architecture review before any code was written.

## Trade-off Analysis

The extra RLS complexity is small and one-time; the alternative is a real data-exposure bug. Not a close call.

## Consequences

- Easier: nothing — this is strictly more policies than the naive version, but it's the correct behavior, not a trade-off against something better.
- Harder: any new table holding parent-facing LLM output needs the same role-restricted pattern applied deliberately — it's not the default you get from just scoping by `family_id`. Future engineers adding tables should check this ADR.
- Revisit when: never, by design — this is a product boundary, not a default.

## Action Items

1. [ ] Phase 1: write role-restricted RLS policies for all five affected tables, not just family-scoped ones
2. [ ] Code review checklist: any new parent-facing table needs the same treatment
