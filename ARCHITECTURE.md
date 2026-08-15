# Architecture — Parent-Child Emotional Wellbeing App

**Product statement:** Help parents understand their children's perspectives and emotions to build more empathetic and meaningful relationships.

This document is the system design for the product that grows out of the `EmotionPOC` benchmark (see [PERFORMANCE_COMPARISON.md](PERFORMANCE_COMPARISON.md)). The POC proved server-side LLM (Gemini `gemini-flash-lite-latest`) beats on-device for both latency and insight quality on the "overview" task — this design builds on that conclusion.

For phased rollout and deferred items, see [PLAN.md](PLAN.md).

---

## 1. Requirements

### Functional
- **Child**: submit an emotion log entry (valence, labels, associations, optional journal text). **Child is feed-only** (user decision) — no reflections, overview, or how-to-react tips are ever shown on the child side; see §3 RLS.
- **Parent**: gets a push notification on every new child log entry, with a short "how to react" tip.
- **Parent**: opens a **Relationship Overview** — LLM synthesis of all child logs + parent context into headline/summary/patterns/relationship_signal/key_insight (existing `overviewPrompt` shape).
- **Parent**: requests **Reflection Recommendations** — LLM-generated recommendations based on the child's full log history (MVP2).
- **Crisis safety net**: any child entry showing a self-harm/suicide signal gets escalated to the parent immediately, with verified crisis-resource contacts — independent of and higher-priority than the ordinary how-to-react flow. See §2b, mandatory for MVP1 (not deferred).
- Single iOS app, two roles (parent / child), linked via an email-invite pairing flow (§3b) — **not** Apple Family Sharing, `families`/`profiles` are our own construct.
- **Either mode, everywhere, per person**: each profile — parent or child — can independently switch, from their own Settings view, between **server** (OpenRouter, model configurable per task — [ADR-0010](docs/adr/0010-openrouter-llm-gateway.md)) and **on-device** (`FoundationModels`) LLM execution — trading quality/latency for privacy. Per user decision, every LLM touchpoint (`check-log-context`, the "how to react" tip, `generate-overview`, `generate-reflection`) must support both modes, not just the on-demand ones, and the setting is per-user, not family-wide. See §2a.

### Non-functional
- Beta scale: tens–hundreds of families. Optimize for speed-to-ship, not massive scale.
- Emotion/mental-health data for a minor is sensitive — strict tenant isolation (no cross-family reads). Legal/compliance review out of scope for this beta but should reference Indonesia's **UU PDP (Law No. 27/2022, Personal Data Protection)** specifically, not just generic/COPPA-style framing — target users are Indonesian (flagged in [PLAN.md](PLAN.md)).
- LLM API key must never ship inside the client — the POC currently calls Gemini directly from Swift using an env var, which is fine for CLI benchmarking but **not viable in production**.
- **Target users are Indonesian.** All LLM-generated text the parent reads (weekly summary, relationship overview, reflection recommendations, how-to-react tip) is in **Bahasa Indonesia** — user decision, 2026-08-14. `PromptBuilder`'s existing English prompts (incl. the "cautious wording" rules — "may"/"appears to"/"a possible pattern is") are the reference *structure*, not the literal text to ship; they get rewritten in Indonesian with equivalent cautious-language rules ("mungkin", "tampaknya", "kemungkinan pola adalah"), not machine-translated as-is.

### Constraints
- Solo build, iOS only (SwiftUI) for now.
- Decided stack: **Supabase** (Postgres + Auth + Realtime + Edge Functions) as BaaS, **APNs** for push. Recommend the **Singapore (`ap-southeast-1`)** project region for latency to Indonesian users — default, not yet explicitly confirmed.
- Decided app structure: **one app, two roles**, not two separate apps.

### iOS frameworks

| Framework | Used for |
|---|---|
| `SwiftUI` | The whole app — already the POC's base |
| `FoundationModels` | `on_device` mode, all four touchpoints (§2a) — `SystemLanguageModel`/`LanguageModelSession`, same API the POC's `BenchmarkService.swift` already exercises |
| `AuthenticationServices` | Sign in with Apple (§7 default), for both parent signup and child invite-acceptance (§3b) |
| `UserNotifications` | Push permission request; handling incoming how-to-react and crisis-alert pushes (§5, §2b) |
| `UIKit` (just `@UIApplicationDelegateAdaptor`) | SwiftUI's `App` protocol has no hook for `didRegisterForRemoteNotificationsWithDeviceToken` — need a thin delegate adaptor purely for APNs device-token registration |
| `Foundation` | `URLSession`, `JSONDecoder`/`Encoder`, `DateFormatter` — already used throughout the POC's `Models.swift` |
| **`supabase-swift`** (official client, not an Apple framework) | Postgres queries (RLS-enforced), Auth session management, Edge Function invocation — replaces most hand-rolled networking |
| `WidgetKit` | Parent-side home-screen widget — overview + how-to-react tip glance (§3c) |

**Explicitly not used (for now)**: `HealthKit` (§3 — vocabulary-copy decision, no framework import). `AppIntents` — the current widget scope is read-only glance, not interactive, so there's no action for an `AppIntent` to perform; would come back if a quick-log widget gets picked up later (§3c). No hard `Combine` dependency — async/await covers it, and `supabase-swift` is async/await-native.

**New entitlement: App Groups.** The widget extension runs as a separate process/sandbox from the main app, so it needs a way to read the small display cache (latest tip/overview text) the main app writes for it — a shared App Group container (e.g. `group.com.radityaaydin.EmotionPOC`, plain shared storage like `UserDefaults(suiteName:)`, not Keychain). Nothing auth-sensitive crosses this boundary in the current read-only-widget scope — see §3c for why that's lighter than it first looked.

**What carries over from the POC vs. what doesn't**: `BenchmarkService.swift`'s on-device call pattern and `PromptBuilder.swift` (once rewritten in Indonesian) both reuse directly into the real app's `on_device` path. `ServerGemini.swift` — the POC's raw `URLSession` SSE client that calls Gemini directly — **does not carry over**: in the real app, `server` mode goes through Supabase Edge Functions calling OpenRouter ([ADR-0010](docs/adr/0010-openrouter-llm-gateway.md)), not a direct Gemini call, and never directly from the client either way. That file stays useful as the Phase 0 benchmark harness, not as production code.

---

## 2. High-level design

```
                        ┌────────────────────────────┐
                        │   iOS App (SwiftUI)         │
                        │   role = parent | child     │
                        └──────────────┬──────────────┘
                                       │ Supabase client SDK (auth'd, RLS-scoped)
                                       ▼
                        ┌────────────────────────────┐
                        │   Supabase Postgres          │
                        │   (families, profiles,       │
                        │    emotion_logs, overviews…) │
                        │   Row Level Security by       │
                        │   family_id + role             │
                        └───┬───────────┬──────────┬───┘
             DB webhook on │  DB webhook│          │ REST/RPC call
             emotion_logs  │  on        │          │ (generate-overview,
             INSERT        │  how_to_   │          │  generate-reflection)
                            │  react_tips│         │
                            ▼  INSERT    ▼          ▼
              ┌───────────────────┐ ┌───────────┐ ┌─────────────────────┐
              │ Edge Fn:          │ │ Edge Fn:  │ │ Edge Fn:            │
              │ generate-how-to-  │ │ send-how- │ │ generate-overview / │
              │ react (mode-aware,│→│ to-react- │ │ generate-reflection │
              │ §2a — may no-op)  │ │ push      │ │ - calls OpenRouter  │
              └───────────────────┘ └─────┬─────┘ └──────────┬──────────┘
                                           │                  │
                                           ▼                  ▼
                                     ┌─────────┐        ┌─────────────┐
                                     │  APNs    │        │ OpenRouter   │
                                     │ (parent  │        │ (server-side,│
                                     │  device) │        │  key never   │
                                     └─────────┘        │  on client;  │
                                                          │  model per   │
                                                          │  task, §2a & │
                                                          │  ADR-0010)   │
                                                          └─────────────┘
```

Key shift from the POC: **when in server mode**, LLM calls move server-side into Supabase Edge Functions. The Swift `PromptBuilder` (summary/overview prompt shape, cautious-language rules) becomes the reference spec; the runtime prompt logic is ported to TypeScript for the Edge Functions. **In on-device mode**, the diagram above doesn't apply for that call at all — see §2a.

Not shown above (kept out of the diagram to keep it readable, both documented in full elsewhere): the `check-log-context` call that happens *while the child is still writing* an entry, before it's saved (§3a); and the separate `crisis_events` → `send-crisis-alert-push` path (§2b), which fires independently of the happy path shown here.

---

## 2a. LLM execution mode — server vs on-device

`profiles.llm_mode: 'server' | 'on_device'`, default `'server'` (per the Phase 0 POC's own finding — better latency and sharper `key_insight`). **Per-user, not per-family (user decision) — every profile, parent or child, has its own setting, changeable from that person's own Settings view.** This replaces an earlier draft of this doc that had it as a single family-wide, parent-only toggle — that's no longer the design.

**🟡 Known blocker, found 2026-08-15 (Round 2 benchmark, [PERFORMANCE_COMPARISON.md §8a](PERFORMANCE_COMPARISON.md#8a-temuan-kritis--on-device-gagal-total-buat-bahasa-indonesia)), workaround identified but not yet proven end-to-end: `on_device` mode currently does not work at all for this product.** Apple Intelligence's on-device generation does not yet ship Bahasa Indonesia as a supported output language (confirmed via `LanguageModelSession` throwing `unsupportedLanguageOrLocale` on every task, tested live) — and per [ADR-0007](docs/adr/0007-llm-output-language-indonesian.md), Indonesian output isn't optional for this product.

Candidate fix, found 2026-08-15 ([PERFORMANCE_COMPARISON.md §8c](PERFORMANCE_COMPARISON.md#8c-follow-up-2026-08-15-sama-hari--kedua-temuan-di-atas-ditindaklanjuti)): translate around it using Apple's separate `Translation` framework, which *does* support Indonesian on-device (child's Indonesian input → English → run `FoundationModels` in English → translate the English output back to Indonesian). `OnDeviceTranslator.swift` implements the non-SwiftUI-bound half of this (`TranslationSession.init(installedSource:target:)`), confirmed to compile and throw a clear error — but the live test failed with `notInstalled`: the id↔en language pack isn't downloaded on the test host, and there's no way to trigger that download from a headless CLI. The pieces still missing: (1) a SwiftUI-driven download-permission flow (`.translationTask`) wired into the actual app so a real user's device can get the language pack, (2) the full translate-in/translate-out pipeline including *selective* JSON-value translation that leaves structural fields (`relationship_signal.parent_concern: low|moderate|high` etc.) untouched, (3) validation that this actually produces acceptable quality once it runs. **Not yet decided, see §7** whether to pursue this further or just not offer `on_device` in the Settings UI for now.

**Both failures re-confirmed on real hardware, 2026-08-15** ([PERFORMANCE_COMPARISON.md §8d](PERFORMANCE_COMPARISON.md#8d-real-device-retest-2026-08-15-sama-hari--iphone-fisik-via-usb-bukan-mac-hostsimulator)): a physical iPhone (iOS 26.6) connected via USB hit the identical `unsupportedLanguageOrLocale` and `notInstalled` errors — ruling out "it's just a Mac-host/simulator quirk" as an explanation for either blocker. Same test also surfaced something a stable-network dev machine can't: intermittent `NSURLErrorDomain -1005 "connection lost"` failures calling OpenRouter over the phone's real network — `ServerOpenRouter.swift`/`_shared/llm.ts` have no retry logic for this, and production will hit it.

**🟢 Translation workaround confirmed working, 2026-08-16** ([PERFORMANCE_COMPARISON.md §8e](PERFORMANCE_COMPARISON.md#8e-translation-workaround--terbukti-jalan-setelah-language-pack-ke-download-2026-08-16)): added a SwiftUI `.translationTask(source:target:)`-driven button (the only API path that can trigger Apple's language-pack download) to `ContentView.swift`, had the user tap it on the physical iPhone. No visible download dialog appeared, but the pack installed anyway — a fresh app relaunch afterward showed *both* the SwiftUI-driven translate and the plain `OnDeviceTranslator.init(installedSource:target:)` call succeeding, correctly translating "Halo, ini tes terjemahan." → "Hello, this is a translation test." **The workaround is technically viable, not just a theory anymore.** What's still not built: the full translate-in → run-`FoundationModels`-in-English → translate-out pipeline, and selective JSON-value translation that leaves structural fields untouched. Also worth designing around: since no visible permission UI appeared for the user, production can't assume the user will see/approve an explicit dialog on first use — may need the app's own loading state for that first-time download instead.

The mode isn't just "which API do we call" — it changes **which device does the computing**, because `FoundationModels` only runs on-device, so on-device mode literally means the request never leaves whichever device is asking. Since each touchpoint already runs on a specific role's device, "whose mode applies" falls out naturally — it's whoever's device is doing the work at that moment:

| Touchpoint | Whose `llm_mode` governs it | `server` mode | `on_device` mode |
|---|---|---|---|
| `check-log-context` (§3a, child writing an entry) | **Child's own setting** | Child's app calls Edge Function → OpenRouter ([ADR-0010](docs/adr/0010-openrouter-llm-gateway.md)) | Child's app calls local `SystemLanguageModel` directly — **no network round trip at all**, which also sidesteps the write-path latency risk already flagged in §3a |
| "How to react" tip | **Child's own setting** (it's computed on the child's device right at log time, from the child's data) | `generate-how-to-react` Edge Function (webhook on `emotion_logs` INSERT) → OpenRouter → writes `how_to_react_tips` | Child's app computes the tip locally right when logging, writes `how_to_react_tips` itself in the same submission (see §4 — the webhook checks the child profile's `llm_mode` and no-ops if `on_device`, to avoid double compute) |
| `generate-overview` / `generate-reflection` | **Parent's own setting** (parent is the one initiating the request, from their own device) | Edge Function → OpenRouter → caches to `overviews` / `reflections` | **Parent's app** fetches the family's `emotion_logs` + context (already needed to render anything) and calls local `SystemLanguageModel`, reusing the *Swift* `PromptBuilder` directly (no TS port needed for this path) — result is still written to `overviews`/`reflections` via the client SDK for caching/cross-device sync, only the inference call skips the network round trip |

Four consequences worth calling out:
- **Delivery stays server-side either way.** Sending the actual APNs push is decoupled from computing the tip (`send-how-to-react-push`, §4) — it fires off a `how_to_react_tips` INSERT regardless of who wrote that row, so push delivery doesn't care which mode produced the tip.
- **`on_device` mode expands write-RLS.** Previously only Edge Functions (service-role key, bypasses RLS) wrote to `how_to_react_tips`/`overviews`/`reflections`. Now the child/parent client needs a real RLS policy to INSERT into those tables directly, scoped to their own `family_id`. New RLS surface, not just a mode flag.
- **On-device quality trade-off still applies.** Per [PERFORMANCE_COMPARISON.md](PERFORMANCE_COMPARISON.md), on-device output is slower, produces more generic `key_insight`s, and sometimes wraps JSON in a markdown fence (needs `stripFences`-style cleanup on **both** paths, not just server — see `_shared/llm.ts`). This is the actual privacy/quality trade the Settings toggle is making explicit to the user — worth surfacing in the UI copy, not just silently switching.
- **Cross-user tension, worth surfacing in UI copy, not hiding.** A parent who sets their own mode to `server` will have `generate-overview`/`generate-reflection` send the *child's* data to a third-party LLM provider via OpenRouter for that call — even if the child has set their own `llm_mode` to `on_device` for their logging. Each person's setting governs the actions *they* initiate, per user decision, but the child's data is what's being processed either way. Worth the overview/reflection screen being explicit about which mode is about to run, since it's not purely the child's call once the data exists in Supabase.

---

## 2b. Guardrails

User decision: default to Indonesian rules where they exist; where they don't (notably: AI-specific crisis-response behavior), pull from the relevant established international standard rather than invent one.

### What actually applies here (researched, not assumed)

| Source | What it requires of us |
|---|---|
| **UU PDP (Law 27/2022)**, Art. on specific/sensitive data | Health data **and** children's data (under 18) are both separately classified as sensitive — this app triggers *both* categories at once. Requires stricter protection + **explicit, specific consent** (not bundled into a generic ToS checkbox) before processing. |
| **PP Tunas (PP 17/2025)** + its technical rules, Permen Komdigi 9/2026, effective 2026‑03‑28 | Child-protection obligations for any electronic system a child uses: risk assessment, age-based access control, parental-control features, children's-data protection, a content-moderation system, and an **easy complaint mechanism**. The under-16 social-media-account restriction doesn't apply to us directly (we're not social media), but the rest does. |
| **SE Menkominfo 9/2023** (AI ethics circular) | AI must not be the sole determinant of a decision about a person. Backs up what the prompts already do (cautious language, no diagnosis) — now with an actual regulatory citation, not just good practice. |
| **No Indonesia-specific rule found for AI + youth self-harm content.** Falling back to **#chatsafe** (Delphi-consensus safe-messaging guidelines for young people discussing self-harm/suicide online) and the general AI-safety consensus from recent chatbot-safety research: never produce method-related content, never romanticize, always hard-redirect to real human help, never let the model try to "handle" a crisis itself. | Shapes the crisis-detection design below. |

### Crisis detection & escalation (new — belongs in Phase 2/MVP1, not deferred)

This is a hard safety requirement, independent of the "how to react" RAG work that *is* deferred (§ Phase 4 in [PLAN.md](PLAN.md)) — don't conflate the two.

- **Two layers, not one.** A deterministic ID/EN keyword pre-filter (e.g. "bunuh diri", "mengakhiri hidup", "self harm", "nggak mau hidup lagi") runs first, client-side, synchronously, no network or LLM needed — this exists *because* chatbot-safety research shows LLM-only detection misses cases, and because on-device model quality is already known to be weaker (§2a). A secondary LLM pass (folded into `check-log-context`'s extraction call, §3a — same mode-aware branching as everything else in §2a) catches subtler phrasing the keyword list misses. Both run **while the child is still composing**, before the normal §3a flow would otherwise save anything.
- **Either layer flags it → immediate escalation, which forces an early save.** This is the one exception to §3a's rule that `emotion_logs` only gets INSERTed once every follow-up is answered: the moment either layer flags a crisis signal, the client immediately INSERTs the `emotion_logs` row as-is (whatever's been entered so far — valence, labels, partial journal text), with **`context_complete = false`**, specifically so `crisis_events` has a real row to reference. The child can still finish the normal follow-up flow afterward (or not — the entry already exists either way); completing it later just adds `log_context_answers` rows and flips `context_complete` to `true`, it doesn't re-trigger another crisis check or another push. This is also, right now, the *only* path that produces an incomplete (`context_complete = false`) entry — the ordinary happy path in §3a never does, since it only inserts once everything's already answered.
- **The parent-facing message is a static, verified resource card — never LLM-generated.** Given the stakes of getting this wrong, we don't trust any model — server or on-device — to compose a crisis response; we send a fixed template with real, checked contacts (see below), consistent with #chatsafe's "hard-redirect to real help" rule.
- **Delivery is its own path**, `send-crisis-alert-push` — separate from `send-how-to-react-push`, higher-priority notification category, fires off a `crisis_events` INSERT regardless of `llm_mode`.
- New table: `crisis_events (id, emotion_log_id FK **not null** — always has a row to point to, per the early-save rule above, detected_at, detection_method 'keyword'|'llm', acknowledged_by_parent boolean, created_at)` — also functions as the audit trail PP Tunas–style compliance will eventually expect.

**Current verified crisis resources for the template** (checked 2026‑08‑14, re-verify periodically — a wrong number here is actively harmful):
- **SEJIWA — 119 ext. 8**, Kemenkes-backed, free, 24 hours. Note: multiple reports of slow response / difficulty getting through, so it should not be the *only* number shown.
- **LISA Helpline (Love Inside Suicide Awareness) — 0811‑3855‑472**, free, 24/7, nationwide despite being Bali-based.
- Nearest **Puskesmas or hospital ER** — Kemenkes's own fallback recommendation.
- *Not* included: Into The Light Indonesia — it's an advocacy/education organization, confirmed to **not** run a live hotline or peer-support line; listing it as a crisis contact would be actively misleading.

### Other guardrail requirements to build in (not just detection)

- **Explicit, specific consent** for sensitive-data processing (UU PDP) — particularly a separate, explicit consent moment for `server` mode specifically, since that's when child mental-health data leaves the device to a third-party LLM provider via OpenRouter ([ADR-0010](docs/adr/0010-openrouter-llm-gateway.md)). Don't fold this into general app ToS.
- **Complaint/reporting mechanism** (PP Tunas) — not yet in the design; add a lightweight "report a concerning result" action on any LLM-generated output (overview, reflection, how-to-react tip), routed somewhere a human reviews it. New Phase 2 item.
- **Non-diagnostic framing stays mandatory everywhere**, now backed by SE Menkominfo 9/2023, not just product taste — applies to the Indonesian-language prompt rewrite (§ Requirements) too, not only the original English prompts.

Sources: [SE Menkominfo 9/2023 official text (JDIH Komdigi)](https://jdih.komdigi.go.id/produk_hukum/view/id/883/t/surat+edaran+menteri+komunikasi+dan+informatika+nomor+9+tahun+2023) · [UU PDP sensitive-data categories (Fourtrezz)](https://fourtrezz.co.id/uu-perlindungan-data-pribadi-landasan-hukum-kewajiban-bisnis-dan-perlindungan-konsumen/) · [PP Tunas / Permen Komdigi 9/2026 (Merdeka)](https://www.merdeka.com/peristiwa/kpai-desak-pemerintah-tegas-terapkan-aturan-perlindungan-anak-online-di-platform-digital-553805-mvk.html) · [SEJIWA 119 ext 8 (Kompas)](https://www.kompas.com/tren/read/2024/03/14/160000065/ramai-soal-hotline-kesehatan-jiwa-119-tidak-bisa-dihubungi-kemenkes--ada?page=all) · [LISA Helpline contact (BISA Helpline)](https://bisahelpline.org/hotline-layanan-cegah-bunuh-diri-hadir-di-bali/) · [Into The Light Indonesia — no active hotline](https://www.intothelightid.org/tentang-bunuh-diri/hotline-bunuh-diri-di-indonesia/) · [#chatsafe guidelines (NCBI)](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10395901/)

---

## 3. Data model (Postgres)

```
families
  id, name, timezone, created_at
  -- purely our own construct — no Apple Family Sharing involved, see §3b

profiles
  id (= auth.users.id), family_id, role ('parent'|'child'),
  display_name, age, relationship,
  llm_mode ('server'|'on_device') default 'server', created_at
  -- llm_mode is per-profile, not per-family — each person sets their
  -- own, from their own Settings view — see §2a
  -- no `healthkit_enabled` toggle — see note below, we don't touch
  -- the HealthKit framework at all

device_tokens
  id, profile_id, apns_token, created_at
  -- only parent profiles register tokens; child role doesn't need push

invites                        -- parent→child pairing, see §3b
  id, family_id, invited_email, invited_role ('child'),
  invited_by (FK profiles), token, status ('pending'|'accepted'|'expired'),
  created_at, expires_at

emotion_logs
  id, child_id (FK profiles), family_id, timestamp, source,
  kind ('dailyMood'|'momentaryEmotion'), valence,
  labels text[], associations text[], journal text,
  valence_classification text GENERATED ALWAYS AS (…) STORED,
  context_complete boolean, created_at
  -- true once every log_context_field the LLM couldn't extract has
  -- been answered via follow-up (§3a). In the normal flow the row
  -- only ever gets INSERTed once this is already true — the sole
  -- exception is a crisis-flagged entry (§2b), saved immediately as
  -- incomplete so crisis_events has something to point to.
  -- valence_classification is a Postgres generated column, not
  -- app-supplied — single source of truth, can't drift from valence
  -- (thresholds are a placeholder, see note below)

crisis_events                  -- guardrail audit trail, see §2b
  id, emotion_log_id (FK, not null), detected_at,
  detection_method ('keyword'|'llm'), acknowledged_by_parent boolean,
  created_at

log_context_answers            -- guided-journaling follow-up answers
  id, emotion_log_id (FK), field log_context_field, answer text,
  source ('extracted'|'manual'), created_at
  -- one row per field, once known — either the LLM extracted it
  -- from free text, or the child answered the follow-up question

parent_interactions            -- maps to existing RecentInteraction
  id, parent_id, family_id, timestamp, topic, interaction, parent_emotion

parent_reflection_logs         -- maps to existing ParentLog
  id, parent_id, family_id, timestamp, emotion, note

overviews                      -- cache, avoid regenerating on every open
  id, family_id, generated_at, headline, summary,
  patterns jsonb, relationship_signal jsonb, key_insight, raw_response jsonb

reflections                    -- MVP2 cache
  id, family_id, generated_at, recommendations jsonb, raw_response jsonb

how_to_react_tips
  id, emotion_log_id (FK), generated_at, tip text, raw_response jsonb
```

**Vocabulary, not integration (user decision):** `kind`, `labels`, and `associations` reuse the same string vocabulary as Apple's real HealthKit "State of Mind" feature (`HKStateOfMind.Kind` / `.Label` / `.Association`) — the child's emotion slider is deliberately modeled after that UX. But **we do not import the HealthKit framework or write real `HKStateOfMind` samples.** These become plain Swift enums (client) / a Postgres `enum` type for `kind` (fixed at 2 values) and `text[]` + a lookup-table-backed trigger for `labels`/`associations` (open-ended, meant to expand — a plain Postgres `CHECK` can't reference another table, so membership is validated in `validate_emotion_vocabulary()`, see `supabase/migrations/`) — all sharing Apple's values. This was an explicit choice: it keeps the same familiar slider UX and label set without pulling in HealthKit entitlements, on-device-only data access, background sync workers, or the elevated App Store scrutiny that comes with writing real mental-health-category HealthKit data — all of which would apply if we integrated with the real API. Revisit only if there's a concrete reason to want cross-app sync with Apple Health later.

- `kind`: `dailyMood` | `momentaryEmotion` (full base set for MVP; expanding to match every value Apple documents is an implementation-time task, not decided here).
- `labels` / `associations`: the values already used in the dummy dataset are the MVP base set (`calm`, `hopeful`, `frustrated`, `annoyed`, `lonely`, `sad`, `worried`, `proud`, `excited`, `stressed`, `overwhelmed`, `irritated`, `amused`, `happy`, `discouraged`, `indifferent` / `family`, `education`, `friends`, `tasks`) — expand later by referencing Apple's published State of Mind label/association list, don't hard-code a guessed full list now.
- `valence_classification` buckets (positive / slightlyPositive / neutral / slightlyNegative / negative): exact thresholds are **not yet finalized** — the generated-column expression above is a placeholder shape, not final values. Small, non-blocking decision to make at implementation time.

**RLS policy shape**: every table filters on `family_id = (select family_id from profiles where id = auth.uid())` — but that alone is *not* sufficient, see the role restriction below.

**Child is write-only for LLM outputs — this is a hard product boundary, not just a default (user decision).** The child feeds data; reflections and the how-to-react tip are for the parent alone. Concretely:
- `emotion_logs` INSERT only allowed where `child_id = auth.uid()` and role = `child`.
- `overviews`, `reflections`, `how_to_react_tips` — **SELECT restricted to `role = 'parent'` within the family.** Family-scoping alone (as originally written in this doc) would have let the child read these too, since they share the same `family_id` — that was a gap, now closed. The child may still `INSERT` into `how_to_react_tips` in `on_device` mode (§2a — their device computes it), but that's write-only: no matching SELECT grant, so they can't read it back.
- `crisis_events` — SELECT restricted to `role = 'parent'`, same reasoning; the child can `INSERT` (§2b) but not read the family's crisis history.
- `parent_interactions`, `parent_reflection_logs` — SELECT restricted to `role = 'parent'` too, symmetrically: this is the parent's own reflection material about the child, not something the child reads.
- Everything else (`emotion_logs` SELECT, `log_context_answers` SELECT) stays family-scoped both ways, since the child needs to see their own log history and the parent needs to see it for the LLM prompts.
- iOS app follows the same boundary: there is no reflection/overview/tip screen anywhere in the child-side UI, not just a hidden-but-reachable one — Phase 2/3 build list only ever puts those screens on the parent side.

---

## 3a. Guided journaling — follow-up question flow

Source: child's whiteboard design for "details needed before processing (if necessary)".

`log_context_field` enum — the 6 pieces of context an entry should ideally carry, matching the 6 questions in the design:

```
FEELING              -- "how do you feel"
TRIGGER              -- "what makes you feel that way"
PERCEIVED_CAUSE      -- "what do you think the cause/problem is"
PRIOR_EFFORT         -- "effort apa yg sudah dilakuin utk overcome itu"
FUTURE_PLAN          -- "how do you plan to fix it to prevent the same mistake"
EXPECTED_OUTCOME     -- "dari plan itu, kamu ekspek hasilnya gimana"
```

**Trigger mechanism (user decision):** not a static rule, and not fully LLM-judged either — it's an LLM *extraction pass against the enum*. Flow:

1. Child does the quick pick (valence + labels) and can optionally write free text, same as today.
2. Client checks the child's own `profiles.llm_mode` (§2a): `server` → calls the `check-log-context` Edge Function with that free text; `on_device` → calls local `SystemLanguageModel` directly with the same extraction prompt, no network call.
3. Either way, the extraction prompt asks for, per `log_context_field`, either a value found in the child's own text or "not present" — this is a structured-extraction prompt, not open generation, so it stays short/cheap regardless of mode (unlike `generate-overview`).
4. Whatever fields come back "not present" are the ones that get **triggered**: the app shows a follow-up question for exactly those fields, and — per user decision — **once a question is triggered it is mandatory, not skippable**. Fields the LLM already extracted are not re-asked.
5. Client submits the final `emotion_logs` INSERT plus one `log_context_answers` row per field (`source = 'extracted'` or `'manual'`), setting `context_complete = true`. This INSERT is what fires the how-to-react generation (§2a, §4) — so the parent's push is always built from the *complete* structured context, not the raw partial entry.

**Exception:** if either crisis-detection layer fires during step 2–3 (§2b), the client saves the `emotion_logs` row immediately, right then, with whatever's been entered so far and `context_complete = false` — it doesn't wait for step 4/5. That's the one case where an incomplete row exists; everything else always inserts already-complete.

This sits in the child's write path (step 2–3), unlike the other touchpoints which are either async or on-demand — so it's the one where the `server` vs `on_device` choice (§2a) is felt most directly as UX latency, not just as a privacy preference. Worth measuring both paths during Phase 2 build.

---

## 3b. Parent↔child pairing — email invite

**User decision: not Apple Family Sharing.** `families`/`profiles` (§3) are entirely our own construct — no dependency on Apple's Family Sharing or Screen Time APIs for linking accounts. For now, pairing is a plain **email invite**, sent by the parent.

Flow:

1. Parent finishes their own signup (creates a `families` row, becomes that family's first `profiles` row with `role = 'parent'`).
2. Parent enters the child's email in-app → calls `send-family-invite` (Edge Function, service-role). This — not a direct client `INSERT` — is what creates the `invites` row: the token needs to be generated with a strong RNG, and a client can't be trusted to do that itself for something this security-sensitive.
3. `send-family-invite` calls Supabase Auth's built-in **`admin.inviteUserByEmail()`** to actually send the email — purpose-built for exactly this "invite a specific person, they complete signup, get linked" pattern, avoids standing up a separate transactional-email integration (Resend/Postmark/etc.). The token rides along in the `redirectTo` deep link so it survives the round trip to the child's device.
4. Child opens the emailed link, completes their own auth (Sign in with Apple, per §7's default assumption), lands in-app already carrying the invite token from the redirect URL.
5. `accept-family-invite` Edge Function (service-role — the invitee isn't part of the family yet, so plain client-side RLS can't do this step) validates the token against the invite row (including that the invited email matches the now-authenticated user's), creates the child's `profiles` row with that `family_id` and `role = 'child'`, marks the invite `accepted`.

RLS: `invites` — parent can `SELECT` rows for their own `family_id`. Deliberately **no INSERT/UPDATE/DELETE policy at all** — creating one goes through `send-family-invite`, accepting one through `accept-family-invite`, both service-role. This was a correction during implementation: an earlier draft had a direct client-`INSERT` RLS policy for parents, which would have meant trusting client-supplied tokens.

Not yet decided (flagged in §7): invite token expiry duration, whether a parent can resend/revoke a pending invite, and whether a child needs their own Apple ID/email to begin with (worth a light touch on age-appropriate account creation, tying back to the PP Tunas guardrails in §2b — flagging the connection, not re-litigating it here).

---

## 3c. Home-screen widget (parent — overview + tip glance)

**Scope, narrowed by user decision (2026-08-14):** for now, widgets are **parent-side, read-only glance only** — the latest Relationship Overview headline, and the latest "how to react" tip once the child has submitted a log. No child-side widget, no interactive quick-log from the home screen — that's not in scope right now (was explored, deliberately dropped for the moment, not carried into Phase 4 below).

Because it's read-only, this turns out simpler than the original draft of this section: **no `AppIntents` needed** (that framework is only for actions performed *from* the widget — nothing here does that), and the widget doesn't need its own live Supabase session at all.

**Design: main app writes a small cache, widget just reads it — no network call from the widget extension.**

1. Main app (which already has an authenticated session) is the only thing that ever talks to Supabase for this data.
2. When a fresh `overviews` row lands (after `generate-overview`), or a fresh `how_to_react_tips` row lands, the main app writes the small bits the widget needs (headline text / tip text, a timestamp, maybe child's name) into a **shared App Group container** — plain shared storage (e.g. an `UserDefaults(suiteName:)` backed by the App Group, or a small shared file), not Keychain, since nothing sensitive-auth-wise needs to cross the boundary anymore.
3. Main app calls `WidgetCenter.shared.reloadTimelines(ofKind:)` right after, so the widget's `TimelineProvider` picks up the new cache promptly instead of waiting on WidgetKit's own (coarse) refresh budget.
4. **The tip case needs the app to run even when not foregrounded**, since the whole point is "parent sees the tip after the child logs, without opening the app." `send-how-to-react-push` (§4, §5) should send the payload as both a visible alert *and* `content-available: 1` (background push) — the visible alert covers the notification banner as already designed, and the background flag wakes the app briefly to do step 2–3 above. Best-effort, not guaranteed-instant (iOS throttles background push under Low Power Mode etc.) — same caveat as WidgetKit's own refresh budget, not a new one.
5. Worth putting the display fields directly in the push payload itself (tip text, headline if relevant) rather than making the background-woken app do a fresh Supabase fetch — one less round trip.

Single `WidgetKit` extension target, one or two widget families (e.g. small = latest tip, medium/large = overview highlights) — exact layout is a UI detail, not architecturally blocking, left open.

If a quick-log widget gets picked back up later, that's when `AppIntents` and the shared-Keychain App Group pattern from the earlier draft of this section would actually be needed — noted here so that thread isn't lost, not designing it now.

---

## 4. API surface

Most reads/writes go straight through the **Supabase client SDK** (RLS does the authorization — no custom API needed):
- Child: `INSERT emotion_logs`, `SELECT` own `emotion_logs`/`log_context_answers` — **no SELECT grant** on `overviews`, `reflections`, `how_to_react_tips`, `crisis_events`, `parent_interactions`, or `parent_reflection_logs` (§3 RLS — child is feed-only).
- Parent: `INSERT parent_interactions`, `INSERT parent_reflection_logs`, `SELECT` everything family-scoped.
- Parent: `UPSERT device_tokens` (register APNs token on launch / token refresh).
- **`on_device` mode only** (§2a, per-profile): child's client `INSERT`s directly into `how_to_react_tips` (write-only — no SELECT grant, per §3); parent's client `INSERT`s directly into `overviews`/`reflections`. Needs its own RLS policy, since previously only Edge Functions (service-role key) wrote these.
- Child: `INSERT crisis_events` when the client-side keyword pre-filter (§2b) flags an entry — always client-writable, both modes (no network dependency), but again write-only, no SELECT.
- Parent: `SELECT invites` for their own `family_id` (§3b) — no client INSERT; creating one is `send-family-invite` only, see below.

Custom **Edge Functions** (the only place the OpenRouter API key lives, [ADR-0010](docs/adr/0010-openrouter-llm-gateway.md) — skipped per-call whenever the relevant profile is in `on_device` mode, per §2a):

| Function | Trigger | Does |
|---|---|---|
| `check-log-context` | Client call, while child is composing an entry (pre-save) — only when the **child's own** `llm_mode = server`, see §2a | Extracts `log_context_field` values from free text (§3a), plus a secondary LLM-based crisis-signal check (§2b, backs up the always-on keyword pre-filter); returns which fields are missing and whether to escalate |
| `generate-how-to-react` | DB webhook on `emotion_logs` INSERT (fires only once `context_complete = true`) | Checks the **child's own** `profiles.llm_mode` first — no-ops if `on_device` (client already wrote the tip itself). If `server`: generates the tip (plain LLM, no grounding — see [PLAN.md](PLAN.md)) from the full structured context, writes `how_to_react_tips` |
| `send-how-to-react-push` | DB webhook on `how_to_react_tips` INSERT | Mode-agnostic — fires regardless of whether the row came from `generate-how-to-react` or a client writing it directly in `on_device` mode. Builds the push payload and sends via APNs. No LLM call here. |
| `send-crisis-alert-push` | DB webhook on `crisis_events` INSERT | Mode-agnostic, always fires. Sends a **static, verified resource card** (§2b) — never LLM-generated — via APNs as a high-priority notification. No LLM call here either. |
| `generate-overview` | Client call, `POST {family_id}` — only when the **parent's own** `llm_mode = server` | Builds prompt from logs + parent context (ports `overviewPrompt`), calls OpenRouter, validates JSON, writes to `overviews`, returns it |
| `generate-reflection` | Client call, `POST {family_id}` — only when the **parent's own** `llm_mode = server` | Same shape, new reflection-oriented prompt (MVP2), writes to `reflections` |
| `send-family-invite` | Client call (parent), `POST {invited_email}` | Service-role: mints a server-generated token, writes the `invites` row, calls `admin.inviteUserByEmail()` (§3b) |
| `accept-family-invite` | Client call with invite token, right after a newly-invited child completes auth (§3b) | Service-role: validates token against `invites` (incl. that the invited email matches the now-authenticated user), creates the child's `profiles` row scoped to that `family_id`, marks invite `accepted` |

---

## 5. Notifications (APNs)

- Apple Push Notification Auth Key (`.p8`) stored as an Edge Function secret.
- `send-how-to-react-push` (§4) builds the push payload (child's name + log preview + how-to-react tip) and sends via APNs HTTP/2 using JWT provider auth — same delivery path regardless of `llm_mode`, since it only reacts to a `how_to_react_tips` row existing.
- Payload carries both a visible alert (banner) **and `content-available: 1`** — the alert is the notification itself, the background flag wakes the app briefly to refresh the widget's cache (§3c), so the tip glance widget updates without the parent needing to open the app.
- Only **parent** profiles register device tokens — child role never needs push in this design.
- iOS app requests push permission during parent onboarding.

---

## 6. Trade-offs made

Full context/options/consequences for the starred rows are written up as ADRs in [docs/adr/](docs/adr/README.md) — this table is the fast-scan index, not the only copy of the reasoning.

| Decision | Chosen | Why | Revisit when | ADR |
|---|---|---|---|---|
| BaaS vs custom backend | Supabase | Beta scale, solo build — Postgres is portable if we outgrow it | Real scale, or need infra Supabase doesn't offer | [0001](docs/adr/0001-supabase-backend-platform.md) |
| Push mechanism | APNs direct push | User wants real notification even when app is backgrounded/closed | N/A — this is the correct default for this requirement | — |
| App structure | One app, two roles | Simpler for a family (less to install/maintain) vs two codebases | If parent/child UX diverges enough to need fully separate nav/design systems | — |
| LLM call location (`server` mode) | Edge Functions, key never on client | POC's client-side API key is not production-safe | N/A — not revisiting this one | [0001](docs/adr/0001-supabase-backend-platform.md) |
| LLM provider (`server` mode) | OpenRouter, per-task configurable model — not a direct Gemini client | User decision — avoid single-provider lock-in, make model choice an env var, not a code change | Once real usage data suggests a different model per task | [0010](docs/adr/0010-openrouter-llm-gateway.md) |
| DB webhook secret storage | Supabase Vault, not `alter database ... set app.settings.*` | Found during live deployment: the GUC approach needs true superuser, which Supabase's managed Postgres doesn't grant even to the `postgres` role — confirmed via a real permission-denied error, 2026-08-14 | N/A — closes a real deployment blocker, same category as the earlier crisis-events/RLS fixes | — |
| LLM execution mode (§2a) | User-switchable `server`/`on_device`, **per-profile** | Explicit user decision — each person controls their own privacy/quality trade-off, must cover every LLM touchpoint | N/A — this is now a permanent product surface | [0002](docs/adr/0002-per-profile-llm-execution-mode.md) |
| HealthKit vocabulary (§3) | Copy the strings, skip the framework | Familiar UX without entitlements/App Review overhead for mental-health-category HealthKit data | If cross-app Health sync becomes a real requirement | [0003](docs/adr/0003-healthkit-vocabulary-without-framework.md) |
| Pairing mechanism (§3b) | Email invite, not Apple Family Sharing | Explicit user decision — app doesn't depend on Apple's family-account graph | Revisit if invite friction (child needing their own email/Apple ID) turns out to be a real adoption blocker | [0004](docs/adr/0004-email-invite-pairing.md) |
| Invite token generation | Server-side (`send-family-invite`, service-role), not client-supplied | Found during implementation: a direct client `INSERT` policy on `invites` would mean trusting the client to generate a strong token — not guaranteed | N/A — closes a real gap, same category as the crisis-events early-save fix above | [0004](docs/adr/0004-email-invite-pairing.md) |
| Child data access | Feed-only — no SELECT on `overviews`/`reflections`/`how_to_react_tips`/`crisis_events`/parent logs | Explicit user decision — reflections and tips are for the parent to act on, not for the child to see | N/A — this is a product boundary, not a default | [0005](docs/adr/0005-child-feed-only-data-access.md) |
| Tip compute vs delivery | Split into `generate-how-to-react` (mode-aware compute) + `send-how-to-react-push` (mode-agnostic delivery) | Needed once compute could happen on-device (client-written row) or server-side (Edge Function-written row) — one delivery path had to work for both | N/A | [0002](docs/adr/0002-per-profile-llm-execution-mode.md) |
| Guardrails & crisis detection (§2b) | Indonesian regs where they exist (UU PDP, PP Tunas, SE Menkominfo 9/2023) + #chatsafe for crisis response | User decision — default local, fall back to established international standard for the gap | Keyword list needs domain-expert pass; contacts need periodic re-verification | [0006](docs/adr/0006-guardrails-indonesian-compliance-and-crisis-safety.md) |
| "How to react" grounding | Plain LLM (no RAG) | Explicit MVP scope decision — ship the flow first | See [PLAN.md](PLAN.md) — flagged as next major feature after MVP1/2 land | — |
| LLM output language | Bahasa Indonesia | Target users are Indonesian | Not expected to change | [0007](docs/adr/0007-llm-output-language-indonesian.md) |
| Follow-up trigger (§3a) | LLM extraction against a fixed enum, not a static rule | User decision — smarter than a text-length rule, cheaper/more predictable than open-ended LLM judgment | Mode choice (§2a) already covers the latency escape hatch — no separate fallback needed | [0008](docs/adr/0008-guided-journaling-extraction-flow.md) |
| Follow-up skippability | Mandatory once triggered | User decision — a field the LLM flagged as missing must be answered before the log counts as complete | N/A | [0008](docs/adr/0008-guided-journaling-extraction-flow.md) |
| Crisis-flagged entries save early | Immediate partial `emotion_logs` INSERT (`context_complete = false`) the moment either crisis layer fires, bypassing §3a's normal "only save once complete" rule | Found during architecture review: `crisis_events.emotion_log_id` is `not null`, but §3a's happy path never has an incomplete row to reference — without this exception, crisis detection would have nowhere valid to point | N/A — this closes a real gap, not a preference | [0006](docs/adr/0006-guardrails-indonesian-compliance-and-crisis-safety.md) |
| Widget scope | Read-only parent glance, no `AppIntents` | User decision — narrowed from an interactive quick-log exploration | If quick-log widgets get picked back up | [0009](docs/adr/0009-widget-scope-read-only-glance.md) |

---

## 7. Open, non-blocking items

- **🟢 `on_device` mode: base generation still doesn't work, but a confirmed-viable workaround exists (§2a)**: Apple Intelligence doesn't support Indonesian output yet — confirmed live on both a Mac host and a physical iPhone (iOS 26.6), 2026-08-15. The translate-around-it workaround (Apple's `Translation` framework) was proven working end-to-end on the physical device 2026-08-16 (correct id→en translation via the SwiftUI-driven API). Still needed before this is shippable: the full translate-in/translate-out pipeline around `FoundationModels`, selective JSON-value translation, and a decision on how to handle first-time language-pack download in the real UX (no visible system prompt appeared in testing — can't assume the user sees one). See [PERFORMANCE_COMPARISON.md §8a/§8c/§8d/§8e/§8f](PERFORMANCE_COMPARISON.md#8a-temuan-kritis--on-device-gagal-total-buat-bahasa-indonesia).
- **No network-retry logic for OpenRouter calls** (`ServerOpenRouter.swift`, `_shared/llm.ts`): a real-device test over an actual mobile network connection hit intermittent `NSURLErrorDomain -1005` connection-lost failures that a stable-network dev machine never surfaced. Neither the POC client nor the production Edge Functions retry on this — needed before Phase 2, mobile networks aren't as reliable as this project's testing environment has been so far.
- **Free-tier LLM latency — largely fixed, one caveat remains** ([ADR-0010](docs/adr/0010-openrouter-llm-gateway.md)): `check-log-context` measured at 36.5s live, then cut to ~2-7s across all four tasks after finding Nemotron's `/no_think` convention (shipped to production 2026-08-15) — also fixed `generate-reflection`'s English-output bug as a side effect. Still open: whether `check-log-context`'s crisis-signal detection is as reliable under `/no_think` as it was with reasoning enabled — only tested against non-crisis text so far, flagged for the domain-expert review already required for the keyword list (§2b). Rate-limit/429 handling also still has no retry/fallback.
- **Auth provider**: recommend Sign in with Apple (pairs cleanly with Supabase Auth, no password management) — default, not yet confirmed with user.
- **Invite mechanics** (§3b): token expiry duration, resend/revoke a pending invite, and whether email is the only channel or an in-app code gets added later — email invite itself is decided, these details aren't.
- **Whether a child needs their own email/Apple ID to accept an invite** (§3b): not yet addressed — ties into PP Tunas age-appropriate account creation (§2b), worth a real look before Phase 1 ships.
- **`valence_classification` thresholds** (§3): generated-column expression is a placeholder shape, exact bucket boundaries not finalized.
- **Supabase project region**: recommend Singapore (`ap-southeast-1`), not yet explicitly confirmed.
- **App UI language** (menus, buttons, labels — as opposed to LLM-generated text, which is already decided as Indonesian): not yet decided — Indonesian-only vs bilingual/localized toggle.
- **Exact keyword list for the crisis pre-filter** (§2b): needs a real pass by someone with domain expertise (ideally a child psychologist or the #chatsafe research itself), not just the illustrative examples in this doc — flagged so it doesn't get built from a 10-minute brainstorm.
- **Complaint/reporting mechanism** (§2b, required by PP Tunas): who reviews reports, and what the response SLA is — not designed yet, just flagged as required.
- **Widget layout**: which size families show what (small = tip only? overview too?) — a UI detail, not architecturally blocking (§3c).
- **On-device translate-around-the-language-gap pipeline** (§2a): `OnDeviceTranslator.swift` proves the API works but the full flow (SwiftUI download-permission UI, translate-in/translate-out around `FoundationModels`, selective JSON-value translation) isn't built — worth pursuing only once it's decided this is worth the complexity vs. just not offering `on_device` for now.
