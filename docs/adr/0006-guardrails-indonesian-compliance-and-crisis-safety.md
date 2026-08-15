# ADR-0006: Guardrails — Indonesian regulatory basis + #chatsafe-based crisis detection

**Status:** Accepted
**Date:** 2026-08-14
**Deciders:** radityaaydin

## Context

The app processes a minor's emotional/mental-health data through an LLM and surfaces the results to a parent — this is a safety-critical surface, not just a data-privacy one. The user's instruction: default to Indonesian rules where they exist; where they don't, use the relevant established international standard rather than inventing one. Full research and design in [ARCHITECTURE.md §2b](../../ARCHITECTURE.md#2b-guardrails).

## Decision

Three researched Indonesian regulatory sources apply and shape mandatory (not deferred) MVP1 work:

- **UU PDP (Law 27/2022)** — health data and children's data are both separately classified sensitive; requires explicit, specific consent (not bundled into general ToS), particularly for the moment `server` mode sends child data to Gemini.
- **PP Tunas (PP 17/2025)** + Permen Komdigi 9/2026 (effective 2026-03-28) — child-protection obligations: risk assessment, age-based access control, parental controls, children's-data protection, content moderation, and an easy complaint mechanism.
- **SE Menkominfo 9/2023** (AI ethics) — AI must not be the sole determinant of a decision about a person; backs the existing non-diagnostic, cautious-language prompt rules with an actual citation.

No Indonesia-specific rule was found for AI-generated crisis-response behavior. Falls back to **#chatsafe** (Delphi-consensus youth self-harm/suicide safe-messaging guidelines) and general chatbot-safety research consensus: never produce method-related content, never romanticize, always hard-redirect to real human help, never let the model try to "handle" a crisis itself.

Concrete design: a two-layer crisis check (deterministic ID/EN keyword pre-filter, client-side, no network — plus a secondary LLM pass folded into `check-log-context`) escalates immediately via a static, verified resource template (never LLM-generated) — see [ADR-0002](0002-per-profile-llm-execution-mode.md) for the mode-aware branching this reuses, and [ARCHITECTURE.md §2b](../../ARCHITECTURE.md#2b-guardrails) for the current verified contact list (SEJIWA 119 ext. 8, LISA Helpline, nearest Puskesmas/ER — checked 2026-08-14, needs periodic re-verification).

## Options Considered

### Option A: Two-layer detection, static resource template (chosen)
**Pros:** Deterministic keyword layer works even with a weak on-device model or no network; LLM never composes the actual crisis message, removing a hallucination risk on the highest-stakes surface in the product.
**Cons:** Keyword list needs real domain-expert review before ship (flagged, not yet done) — the illustrative examples in the design docs aren't production-ready.

### Option B: LLM-only detection
**Pros:** Simpler, one code path.
**Cons:** Chatbot-safety research cited in this ADR shows LLM-only detection reliably misses cases — rejected as insufficiently safe for this product's stakes.

### Option C: Defer crisis detection to a later phase, ship MVP1 without it
**Pros:** Faster initial ship.
**Cons:** Rejected — this is a hard safety requirement, not a nice-to-have; explicitly kept out of the "deferred / future work" bucket that RAG-grounding and other quality improvements went into.

## Trade-off Analysis

The two-layer, template-based approach costs more upfront design/build effort than trusting the LLM, but the failure mode of an LLM-composed or LLM-missed crisis response is unacceptable for this product's user base (children). Not a close call.

## Consequences

- Easier: nothing — this is added scope, accepted because it's required, not because it's cheap.
- Harder: `crisis_events.emotion_log_id` being not-null required a design fix — see the "Crisis-flagged entries save early" row in [ARCHITECTURE.md §6](../../ARCHITECTURE.md#6-trade-offs-made), found during architecture review: crisis detection forces an early, partial `emotion_logs` save (bypassing the normal "only save once complete" rule in [ARCHITECTURE.md §3a](../../ARCHITECTURE.md#3a-guided-journaling--follow-up-question-flow)) so the audit-trail row has something valid to reference.
- Revisit when: the keyword list gets its domain-expert pass (before ship); crisis resource contacts need periodic re-verification (numbers/services can change).

## Action Items

1. [ ] Phase 2: build both detection layers, `crisis_events` table, `send-crisis-alert-push`
2. [ ] Get a domain-expert (child psychologist or #chatsafe research) pass on the keyword list before ship
3. [ ] Build the explicit consent screen for `server` mode (UU PDP)
4. [ ] Design the complaint/reporting mechanism (PP Tunas) — reviewer + SLA not yet decided
5. [ ] Full compliance/legal review before any public launch (acceptable to defer for personal/beta build — see [PLAN.md](../../PLAN.md))
