# ADR-0001: Supabase as backend platform

**Status:** Accepted
**Date:** 2026-08-14
**Deciders:** radityaaydin

## Context

The `EmotionPOC` benchmark (Phase 0) validated the LLM approach but had no backend at all — data was embedded JSON, and the Gemini API key was called directly from the Swift client via an env var. Moving to a real product needs: persistent multi-family storage, auth, row-level tenant isolation, real-time-ish delivery of a child's log to a parent's device, and a place to hide the LLM API key. Solo build, beta scale (tens–hundreds of families), speed-to-ship prioritized over infrastructure control.

## Decision

Use **Supabase** (managed Postgres + Auth + Realtime + Edge Functions) as the entire backend, plus **APNs** directly for push delivery. Project region: Singapore (`ap-southeast-1`), for latency to Indonesian users (not yet explicitly confirmed with user — see [ARCHITECTURE.md §7](../../ARCHITECTURE.md#7-open-non-blocking-items)).

## Options Considered

### Option A: Supabase (chosen)
| Dimension | Assessment |
|---|---|
| Complexity | Low — RLS handles most authorization, Edge Functions handle the rest |
| Cost | Low at beta scale, usage-based |
| Scalability | Postgres underneath is portable; would need real migration work past a certain scale |
| Team familiarity | N/A (solo build), but well-documented, large community |

**Pros:** Auth + Postgres + Realtime + serverless functions in one product; RLS gives per-tenant isolation almost for free; fast to stand up.
**Cons:** Vendor lock-in to Supabase's specific Edge Function runtime (Deno) and Auth admin APIs; not the cheapest at very large scale.

### Option B: Custom backend (Node/Swift/Python + own Postgres + own auth)
| Dimension | Assessment |
|---|---|
| Complexity | High — auth, RLS-equivalent authorization, realtime, and a push-delivery service all built by hand |
| Cost | Higher upfront (infra + build time), potentially cheaper at large scale |
| Scalability | Full control |
| Team familiarity | N/A |

**Pros:** No vendor lock-in, full control over every layer.
**Cons:** Weeks of infrastructure work before any product feature ships — wrong trade for a solo beta build.

## Trade-off Analysis

Solo build + beta scale means time-to-first-feature matters more than infrastructure ownership. Supabase's RLS model also happens to map cleanly onto this product's core requirement (strict family-scoped, role-scoped data isolation for sensitive minor mental-health data) — see [ADR-0005](0005-child-feed-only-data-access.md).

## Consequences

- Easier: auth, tenant isolation, and serverless compute for LLM calls all come from one vendor with one SDK (`supabase-swift`).
- Harder: migrating off Supabase later would mean re-implementing RLS-equivalent authorization logic and replacing Edge Functions.
- Revisit when: real scale is reached, or a requirement emerges that Supabase's managed offering can't satisfy.

## Action Items

1. [ ] Confirm Singapore region with user before creating the project (see [ARCHITECTURE.md §7](../../ARCHITECTURE.md#7-open-non-blocking-items))
2. [ ] Phase 1 schema + RLS setup — see [PLAN.md](../../PLAN.md)
