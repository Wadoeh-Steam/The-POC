# ADR-0002: Per-profile server/on-device LLM execution mode

**Status:** Accepted
**Date:** 2026-08-14
**Deciders:** radityaaydin

## Context

Phase 0's benchmark ([PERFORMANCE_COMPARISON.md](../../PERFORMANCE_COMPARISON.md)) found server-side Gemini (`gemini-flash-lite-latest`) beats on-device `FoundationModels` on both latency (~3.3× on the overview task) and insight quality (catches parent↔child misalignment more sharply). But the product handles a minor's emotional/mental-health data, and the user wants privacy-conscious families to be able to keep that data from ever reaching a third-party LLM vendor (Gemini). Full mechanism in [ARCHITECTURE.md §2a](../../ARCHITECTURE.md#2a-llm-execution-mode--server-vs-on-device).

An earlier draft of this decision made the toggle family-wide and parent-controlled. The user corrected this: it must be **per-profile** — every person (parent or child) sets their own.

## Decision

`profiles.llm_mode: 'server' | 'on_device'`, default `'server'`, changeable per-person from their own Settings. Every LLM touchpoint (`check-log-context`, the how-to-react tip, `generate-overview`, `generate-reflection`) checks whichever profile is initiating that specific action — not a single family setting.

## Options Considered

### Option A: Per-profile toggle (chosen)
**Pros:** Each person controls their own privacy/quality trade-off; matches how the data actually flows (child's device does the logging-time work, parent's device does the on-demand synthesis).
**Cons:** Introduces a real cross-user tension — a parent in `server` mode still sends the *child's* data to Gemini for `generate-overview`, even if the child chose `on_device` for their own logging. Not hidden: [ARCHITECTURE.md §2a](../../ARCHITECTURE.md#2a-llm-execution-mode--server-vs-on-device) requires this be surfaced in UI copy, not silently resolved.

### Option B: Family-wide toggle, parent-controlled (superseded)
**Pros:** Simpler mental model, one setting to reason about.
**Cons:** Doesn't match user's actual intent — explicitly rejected.

### Option C: No toggle, server-only (rejected)
**Pros:** Simplest to build.
**Cons:** No privacy-conscious option at all — contradicts an explicit product requirement.

## Trade-off Analysis

Per-profile is more complex (RLS has to expand to let clients write `how_to_react_tips`/`overviews`/`reflections` directly in `on_device` mode, since Edge Functions with service-role access are bypassed) but is the only option that matches the actual requirement. The cross-user tension in Option A is a real, accepted cost — not a bug to design away, just something the UI must be honest about.

## Consequences

- Easier: nothing — this is strictly more complex than a single global flag, accepted because it's the actual requirement.
- Harder: RLS surface is larger (new INSERT policies for `on_device`-mode client writes); on-device quality trade-offs from Phase 0 apply per-action now, not per-family.
- Revisit when: never, by design — this is a permanent product surface, not a temporary flag.

## Action Items

1. [ ] Phase 1: `profiles.llm_mode` column + `on_device`-mode RLS policies
2. [ ] Phase 2: per-profile Settings toggle in iOS app, with UI copy that surfaces the cross-user tension rather than hiding it
