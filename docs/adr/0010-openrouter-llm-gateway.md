# ADR-0010: OpenRouter as the LLM gateway, not a direct Gemini client

**Status:** Accepted
**Date:** 2026-08-14
**Deciders:** radityaaydin

## Context

The Phase 0 POC and the initial Phase 1 Edge Function scaffolding both called Google's Gemini API directly (`ServerGemini.swift` in the POC, `_shared/gemini.ts` in the first backend pass) — a hardcoded single-provider client. The user then decided to use **OpenRouter** instead: one API that proxies to many providers/models (Google, Anthropic, OpenAI, and others) behind an OpenAI-compatible interface.

This doesn't reopen the on-device-vs-server conclusion from [PERFORMANCE_COMPARISON.md](../../PERFORMANCE_COMPARISON.md) or [ADR-0002](0002-per-profile-llm-execution-mode.md) — server mode still means "call an LLM API," `on_device` mode is unaffected (it never touches OpenRouter, [ARCHITECTURE.md §2a](../../ARCHITECTURE.md#2a-llm-execution-mode--server-vs-on-device)). What changes is *which provider/model* handles a `server`-mode call, and how easy it is to change that later.

## Decision

`_shared/gemini.ts` is replaced by `_shared/llm.ts`, calling OpenRouter's OpenAI-compatible `chat/completions` endpoint with `OPENROUTER_API_KEY`. Model choice is **per-task, per-environment configurable** via env var (`OPENROUTER_MODEL_EXTRACTION`, `OPENROUTER_MODEL_HOW_TO_REACT`, `OPENROUTER_MODEL_OVERVIEW`, `OPENROUTER_MODEL_REFLECTION`), each with a hardcoded fallback default — not one single model for everything. Structured-output prompts (extraction, overview, reflection) use OpenRouter's `response_format: json_schema`, with the existing `stripFences` cleanup kept as a fallback for providers that don't honor it strictly.

### Default model per task — superseded by a free-tier swap, see below

Original defaults (paid, per-task-appropriate tier — pricing verified 2026-08-14 both via web search and live against `GET https://openrouter.ai/api/v1/models?supported_parameters=structured_outputs`, 319 models support structured outputs):

| Task | Original default | Why it was picked |
|---|---|---|
| `check-log-context` (extraction + **crisis-signal detection**, [ADR-0006](0006-guardrails-indonesian-compliance-and-crisis-safety.md)) | `anthropic/claude-haiku-4.5` ($1/$5 per M) | Single highest-stakes classification in the app — worth paying more for reliability on a safety-critical check that only runs once per log entry. |
| `generate-how-to-react` | `google/gemini-2.5-flash-lite` ($0.10/$0.40) | Purely advisory tone, not detection — cheap tier is fine. |
| `generate-overview` / `generate-reflection` | `google/gemini-2.5-flash-lite` ($0.10/$0.40) | Matches what Phase 0 validated as "good enough." |

**User decision (2026-08-14): switch all four tasks to free-tier OpenRouter models**, including `check-log-context`. This was an explicit trade-off, not an oversight — the user was asked specifically whether crisis-detection should stay on a paid model given the stakes, and chose free-for-everything anyway. Recorded here so it's visible to whoever reads this later, not buried in chat history.

All 5 free + structured-output-capable models found (2026-08-14 live query): `liquid/lfm-2.5-2.6b:free`, `google/gemma-4-26b-a4b-it:free`, `nvidia/nemotron-3-super-120b-a12b:free`, `nvidia/nemotron-nano-9b-v2:free`, `openai/gpt-oss-20b:free`. **All 5 were empirically smoke-tested** (a trivial structured-output request each) before picking a final default — this mattered, because the obvious "pick the biggest model" heuristic actively backfired:

| Model | Result |
|---|---|
| `nvidia/nemotron-3-super-120b-a12b:free` (120B — first choice, on a raw-capacity theory) | **Failed.** Reasoning/thinking model — burned the entire token budget on chain-of-thought at both 100 and 512 `max_tokens`, `finish_reason: length`, never reached the actual JSON. Same failure class [PERFORMANCE_COMPARISON.md](../../PERFORMANCE_COMPARISON.md) already flagged for `gemini-flash-latest` and ruled out — bigger free model, same problem. |
| `liquid/lfm-2.5-2.6b:free` | **Failed differently.** Also a reasoning model; completed at `max_tokens: 1500` but the content was the prompt's placeholder text echoed back verbatim — too small to actually follow the instruction. |
| `nvidia/nemotron-nano-9b-v2:free` | **Works, but needed real calibration.** Reasoning model too (350-570 reasoning tokens on a trivial prompt — real, accepted latency cost). On the *actual* extraction prompt (not the trivial toy test), it initially produced a complete-looking JSON object and then generated blank/whitespace tokens indefinitely instead of stopping — `finish_reason: "length"` at `max_tokens: 2000` even though the real answer only needed ~450 completion tokens once given `max_tokens: 6000` to work with (`finish_reason: "stop"`, parsed correctly). Not an infinite loop, just an unpredictable amount of "wasted" generation before either the real content or termination — **so budgets are set generously (4000-6000 per call site, from the original 256-1024), not tightly.** **Chosen for all four tasks.** |
| `google/gemma-4-26b-a4b-it:free` | **Untestable at decision time.** 429 — OpenRouter's shared free-tier pool was rate-limited by *other users'* traffic, not this app's, on essentially the first real request. |
| `openai/gpt-oss-20b:free` | **Untestable at decision time.** Same 429 shared-pool issue as Gemma. |

**Final decision: `nvidia/nemotron-nano-9b-v2:free` for all four tasks** (`check-log-context`, `generate-how-to-react`, `generate-overview`, `generate-reflection`) — the only one of the 5 confirmed to actually work end-to-end. This includes crisis-signal detection ([ADR-0006](0006-guardrails-indonesian-compliance-and-crisis-safety.md)) — an explicit, asked-and-confirmed user trade-off, not an oversight: **the mandatory keyword pre-filter (§2b) is unaffected by any of this and remains the deterministic, model-independent first line of defense** — that layer is what actually carries the safety guarantee, not this model choice.

**Known, now-confirmed risks, not yet mitigated:**
- **Latency.** Every call pays a real reasoning-token tax (hundreds of tokens of chain-of-thought before the answer, sometimes more) — most consequential for `check-log-context`, which sits on the child's write path ([ADR-0008](0008-guided-journaling-extraction-flow.md)).
- **Shared-pool congestion.** Confirmed directly, not theoretical — two of the five candidate free models were unavailable within minutes of light testing due to *other OpenRouter users'* load, independent of this app's own traffic or the ~20/min, ~200/day per-key caps mentioned in earlier research (also not yet re-verified against this specific account).
- **Edge Function execution timeout, newly relevant.** `maxOutputTokens` is now 4000-6000 per call site (up from 256-1024) specifically to give the reasoning phase room to finish — but a slow generation using most of that budget could plausibly approach Supabase Edge Functions' own execution time limit. Not measured end-to-end (only tested directly against the OpenRouter API, not through a deployed function under a real timeout) — see Action Items.
- No retry/backoff/fallback exists yet for the rate-limit or congestion failure modes — see Action Items. The truncated-JSON failure mode (model loops on whitespace before finishing) is mitigated by generous `maxOutputTokens`, not eliminated — `parseJsonResponse` will still throw if a given call is unlucky enough to exceed even the raised budget, and nothing catches that beyond the generic error handling already in each function.

## Options Considered

### Option A: OpenRouter, per-task configurable model (chosen)
**Pros:** No vendor lock to Google specifically; per-task model choice means the safety-critical call and the quality-critical calls can each use whatever's actually best for them, not one compromise model for everything; changing a model is an env var change, not a code change or redeploy of logic.
**Cons:** Extra layer between the app and the underlying model provider (latency, and dependency on OpenRouter's own uptime); `response_format: json_schema` enforcement depends on which provider OpenRouter routes to, not guaranteed for every model (mitigated by keeping the `stripFences` fallback).

### Option B: Direct Gemini client (original Phase 1 draft, superseded)
**Pros:** One fewer hop, matches the POC's own client exactly.
**Cons:** Locked to one provider; switching models later means rewriting the client, not just an env var.

### Option C: Direct clients per provider (Gemini + Anthropic + OpenAI SDKs, no gateway)
**Pros:** No OpenRouter dependency or fee.
**Cons:** Rejected — three times the client code to maintain for the same outcome OpenRouter already provides in one interface.

## Trade-off Analysis

The extra hop and OpenRouter's ~5.5% fee on top of provider list pricing are small costs at this app's scale, in exchange for genuine flexibility on a decision (which model per task) that's inherently something to empirically tune, not something to lock in once. This project already has the right instinct for that — Phase 0's whole `BenchmarkCLI` exists to A/B this kind of choice — extending that harness to compare OpenRouter models the same way Phase 0 compared on-device vs. server is the natural next step, not yet built (see Action Items).

## Consequences

- Easier: swapping or A/B-testing models per task is an env var change; not locked to Google.
- Harder: one more external dependency (OpenRouter itself) in the request path; need to verify `response_format` support per model/provider rather than assuming it.
- Revisit when: real usage data suggests a different model per task, or OpenRouter itself becomes a bottleneck (latency/uptime) worth removing.

## Action Items

1. [x] `_shared/llm.ts` scaffolded, all four LLM-calling Edge Functions (`check-log-context`, `generate-how-to-react`, `generate-overview`, `generate-reflection`) updated to use it — 2026-08-14.
2. [x] `OPENROUTER_API_KEY` set (`supabase secrets set`) — 2026-08-14.
3. [x] Switched all four task defaults to free-tier models, empirically tested all 5 candidates, settled on `nvidia/nemotron-nano-9b-v2:free` for all four — 2026-08-14/15, user decision, see table above.
4. [x] Raised `maxOutputTokens` per call site (2000/1500/2500/2500) to accommodate the reasoning-token overhead — 2026-08-15.
5. [x] Redeployed all four functions with the final free-tier config — 2026-08-15.
6. [ ] **Handle free-tier rate limiting and shared-pool 429s** — no retry/backoff/queueing exists yet for either failure mode. `check-log-context` failing open (letting the log save without extraction/crisis-check) vs. failing closed (blocking the save) is an explicit product decision that hasn't been made — do not ship without deciding this.
7. [x] **Latency fix found and shipped, 2026-08-15**: NVIDIA Nemotron's `/no_think` system-prompt convention (not a generic OpenRouter param — the `reasoning: {enabled: false}` API parameter barely helped) cuts every task from ~6-36s down to ~2-7s, 0 reasoning tokens, in testing — see [PERFORMANCE_COMPARISON.md §8c](../../PERFORMANCE_COMPARISON.md#8c-follow-up-2026-08-15-sama-hari--kedua-temuan-di-atas-ditindaklanjuti). Added as `systemPrompt` in `_shared/llm.ts`, wired into all four functions, redeployed. **Caveat, not yet resolved**: `check-log-context`'s extraction looked less thorough without reasoning (more fields marked null), and its crisis-signal detection has only been tested against non-crisis text under `/no_think` — flagged for the same domain-expert review already required for the keyword list (ADR-0006).
8. [ ] Extend `BenchmarkCLI` (or a similar small harness) to A/B free vs. paid model output quality on the *actual* prompts (extraction, how-to-react, overview, reflection) — testing so far only confirmed the free model completes and follows instructions on a trivial prompt, not real output quality on this app's specific tasks.
9. [ ] Re-verify OpenRouter pricing/model catalog/free-tier availability periodically — free models in particular can be discontinued or have terms change with little notice.
