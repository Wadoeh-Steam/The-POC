# EmotionPOC — project map

Parent-child emotional wellbeing app for Indonesian families. Product statement: help parents understand their children's perspectives and emotions to build more empathetic and meaningful relationships. Target users are Indonesian — all LLM-generated output is in Bahasa Indonesia (see [ADR-0007](docs/adr/0007-llm-output-language-indonesian.md)).

**Status as of 2026-08-16 — this is a Proof of Concept (POC) / exploration phase, not a shipping product.** Architecture designed, Phase 1 backend deployed live to a test Supabase project (`asjznymcuyzafodpkmgg`, not public), all 8 Edge Functions active. `EmotionPOC/` is still just the Phase 0 benchmark POC extended to compare server-side vs on-device LLM execution with dummy data — not the real iOS app; no Phase 2 client work has started. Docs, decisions, and code here are all subject to change (or a full redo) before/if this moves into an actual build phase — see [PLAN.md](PLAN.md) for current status detail.

## Where to find things — read this before searching

Don't grep across everything to answer "why did we do X" or "how does Y work" — go straight to the right doc:

| Question | Look here |
|---|---|
| What does the system currently do? Data model, API surface, flows, mechanisms | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Why was a specific decision made? Options considered, trade-offs, consequences | [docs/adr/](docs/adr/README.md) — one file per decision |
| What's built, what's next, what phase are we in? | [PLAN.md](PLAN.md) |
| What's still undecided / needs a real answer before it ships? | [ARCHITECTURE.md §7](ARCHITECTURE.md#7-open-non-blocking-items) — **the only copy of this list**, don't recreate it elsewhere |
| Server vs on-device LLM benchmark data (Phase 0) | [PERFORMANCE_COMPARISON.md](PERFORMANCE_COMPARISON.md) |
| Current POC code (Swift models, prompts, benchmark harness — reference for the real app, not the real app itself) | `EmotionPOC/` — see [ARCHITECTURE.md §1 "What carries over from the POC"](ARCHITECTURE.md#1-requirements) |
| Backend implementation (schema, RLS, DB webhooks, Edge Functions) | `supabase/` — migrations are numbered/ordered, functions mirror the table in [ARCHITECTURE.md §4](ARCHITECTURE.md#4-api-surface) 1:1 by name |

## Documentation rules (why this repo won't rot as more engineers touch it)

1. **One fact, one place.** If you're about to write something that's also true elsewhere in the docs, link to it instead of restating it. The Open Items list drifted out of sync between two files once already (caught 2026-08-14) — don't recreate that failure mode anywhere else.
2. **ARCHITECTURE.md describes current state and changes as the system changes.** ADRs are point-in-time and don't get rewritten — if a past decision changes, write a new ADR that supersedes it (mark the old one's Status, don't edit its content), and update ARCHITECTURE.md's relevant section to match the new reality.
3. **New major decision → new ADR**, not a paragraph buried in a random section. Use the template in any existing [docs/adr/](docs/adr/) file. Cross-link it from [ARCHITECTURE.md §6](ARCHITECTURE.md#6-trade-offs-made)'s table.
4. **Don't create new top-level docs for things that already have a home.** New backend work documents into ARCHITECTURE.md's existing structure (new `§N` section if it's genuinely a new subsystem, not a new file) unless it's a full new decision record (→ ADR).
5. Numbered section references (`§2a`, `§3b`, etc.) inside these docs are load-bearing — other files link to them by anchor. If you retitle a section, fix the incoming links (`grep -rn "§" *.md docs/`).
