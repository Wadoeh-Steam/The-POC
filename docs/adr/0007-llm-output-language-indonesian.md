# ADR-0007: LLM-generated output is in Bahasa Indonesia

**Status:** Accepted
**Date:** 2026-08-14
**Deciders:** radityaaydin

## Context

Target users are Indonesian. The Phase 0 POC's prompts ([PromptBuilder.swift](../../EmotionPOC/Services/PromptBuilder.swift)) and their cautious-language rules ("may", "appears to", "a possible pattern is") are all in English.

## Decision

All LLM-generated text a parent reads — weekly summary, relationship overview, reflection recommendations, how-to-react tip — is in Bahasa Indonesia. The English POC prompts are the reference *structure* (cautious-language rules, JSON shape), not literal text to machine-translate. Indonesian equivalents ("mungkin", "tampaknya", "kemungkinan pola adalah") get written as first-class prompt rules, in both the TS (server) and Swift (on-device) copies.

## Options Considered

### Option A: Rewrite prompts in Indonesian (chosen)
**Pros:** Natural for the actual target audience; cautious-language rules can be crafted properly in Indonesian rather than translated awkwardly after the fact.
**Cons:** Doubles the prompt-maintenance surface (Indonesian TS + Indonesian Swift, instead of reusing one English version) — already true anyway per [ADR-0002](0002-per-profile-llm-execution-mode.md)'s TS/Swift split.

### Option B: Keep English, let the child's own language leak through
**Pros:** No prompt rewrite needed.
**Cons:** Rejected — parents' primary reading language is Indonesian; English output would be a real usability regression for the actual target market.

### Option C: Auto-detect and mirror the child's journal language
**Pros:** More adaptive.
**Cons:** Rejected — harder to guarantee consistent cautious-wording quality when the model is also juggling language detection; picked the simpler, controllable option.

## Trade-off Analysis

Straightforward call given the explicit target market — the only real cost is prompt-maintenance surface, which is already duplicated across TS/Swift for other reasons.

## Consequences

- Easier: output reads naturally to the actual users.
- Harder: prompt rewrites need care to preserve the *rules* (non-diagnostic, cautious wording, no raw-number citation) in translation, not just the surface text — this isn't a mechanical translation task.
- Revisit when: not expected to change.

## Action Items

1. [ ] Phase 2: rewrite `summaryPrompt`, `overviewPrompt`, and the new extraction/how-to-react prompts in Indonesian, in both TS and Swift copies
