# Architecture Decision Records

One file per major decision — immutable once accepted. If a decision changes, write a new ADR that supersedes the old one (update the old one's Status to `Superseded by ADR-NNNN`, don't rewrite its content). For current system design (the mutable, evolving description of what the system *is*), see [ARCHITECTURE.md](../../ARCHITECTURE.md) — ADRs are the *why*, ARCHITECTURE.md is the *what*.

| ADR | Title |
|---|---|
| [0001](0001-supabase-backend-platform.md) | Supabase as backend platform |
| [0002](0002-per-profile-llm-execution-mode.md) | Per-profile server/on-device LLM execution mode |
| [0003](0003-healthkit-vocabulary-without-framework.md) | Copy HealthKit's State of Mind vocabulary, don't import the framework |
| [0004](0004-email-invite-pairing.md) | Parent↔child pairing via email invite, not Apple Family Sharing |
| [0005](0005-child-feed-only-data-access.md) | Child is feed-only — no read access to LLM outputs |
| [0006](0006-guardrails-indonesian-compliance-and-crisis-safety.md) | Guardrails — Indonesian regulatory basis + #chatsafe-based crisis detection |
| [0007](0007-llm-output-language-indonesian.md) | LLM-generated output is in Bahasa Indonesia |
| [0008](0008-guided-journaling-extraction-flow.md) | Guided-journaling follow-up via LLM extraction against a fixed enum |
| [0009](0009-widget-scope-read-only-glance.md) | Home-screen widget scope — read-only parent glance, no AppIntents |
| [0010](0010-openrouter-llm-gateway.md) | OpenRouter as the LLM gateway, not a direct Gemini client |

## Adding a new ADR

Next number is `0011`. Use the format in any existing file. Cross-link to the [ARCHITECTURE.md](../../ARCHITECTURE.md) section it affects, and update that section too if the decision changes current behavior — ADRs record *why*, they don't replace updating the system-design doc.
