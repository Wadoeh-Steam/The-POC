# ADR-0008: Guided-journaling follow-up via LLM extraction against a fixed enum

**Status:** Accepted
**Date:** 2026-08-14
**Deciders:** radityaaydin

## Context

Source: child's whiteboard design, "details needed before processing (if necessary)" — 6 follow-up questions (feeling, trigger, perceived cause, prior effort, future plan, expected outcome) meant to enrich the context available to downstream LLM prompts. The open question was what "if necessary" means mechanically: a static rule (e.g. "text is too short"), full LLM judgment ("is this enough context?"), or something else. Full flow in [ARCHITECTURE.md §3a](../../ARCHITECTURE.md#3a-guided-journaling--follow-up-question-flow).

## Decision

Neither a static rule nor open LLM judgment — an **LLM extraction pass against a fixed 6-value enum** (`log_context_field`). The model attempts to extract each field's value from the child's free text; whatever it can't find becomes a mandatory (once triggered, not skippable) follow-up question. Runs mode-aware per [ADR-0002](0002-per-profile-llm-execution-mode.md).

## Options Considered

### Option A: LLM extraction against a fixed enum (chosen)
**Pros:** Smarter than a text-length heuristic (a short but complete entry doesn't get needlessly interrogated); cheaper and more predictable than open-ended "is this sufficient?" LLM judgment, since it's a structured extraction task, not generation.
**Cons:** Sits in the child's write path — this is the one touchpoint where mode choice (§2a) is felt as UX latency, not just privacy preference.

### Option B: Static rule (e.g., trigger if journal text is empty/short)
**Pros:** No LLM call needed, instant.
**Cons:** Crude — a short-but-complete entry gets needlessly interrogated, a long-but-incomplete one might not.

### Option C: Open-ended LLM judgment ("is there enough context here?")
**Pros:** Flexible.
**Cons:** Less predictable output shape, harder to map cleanly onto "which specific questions to ask."

## Trade-off Analysis

The fixed-enum extraction approach costs a network/on-device call on the write path but produces a precise, per-field trigger — worth it given how central write-time friction is to this product's core "feeding data" motion.

## Consequences

- Easier: predictable, structured follow-up triggering; the resulting `log_context_answers` rows are individually attributable (`extracted` vs `manual`).
- Harder: write-path latency needs measuring per mode during Phase 2 build; interacts with crisis detection (§2b) — the crisis check is folded into this same extraction call, see [ADR-0006](0006-guardrails-indonesian-compliance-and-crisis-safety.md).
- Revisit when: not expected — mode choice (§2a) already covers the latency escape hatch, no separate fallback needed.

## Action Items

1. [ ] Phase 2: `check-log-context` Edge Function (server) + on-device extraction prompt (Swift)
2. [ ] Measure extraction latency in both modes during build
