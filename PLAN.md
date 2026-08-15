# Build Plan — Parent-Child Emotional Wellbeing App

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full system design this plan implements.

## Status

- **Phase 0 — POC benchmark**: ✅ done, two rounds. Round 1 (2026-08-14, [PERFORMANCE_COMPARISON.md §1-6](PERFORMANCE_COMPARISON.md)): Gemini-direct vs on-device, English prompts, `summary`/`overview` tasks — decided server-side for MVP. Round 2 (2026-08-15, [§8](PERFORMANCE_COMPARISON.md#8-round-2-2026-08-15--openrouter-free-tier--prompt-bahasa-indonesia-4-task-produksi)): re-ran against the *actual* production setup (OpenRouter free tier, Indonesian prompts, all 4 real touchpoints) — found `on_device` mode currently fails outright for Indonesian output (Apple Intelligence platform limitation, not a bug) and the free-tier server path has real latency/language-consistency problems. Both flagged in [ARCHITECTURE.md §7](ARCHITECTURE.md#7-open-non-blocking-items).
- **Phase 1 — Backend**: ✅ deployed and live, 2026-08-14/15 (project `asjznymcuyzafodpkmgg`) — schema, RLS, DB webhooks, all 8 Edge Functions, OpenRouter integration. See the Deployment status section below.
- **iOS POC extension** (2026-08-15): `EmotionPOC`/`BenchmarkCLI` targets updated to benchmark the *real* production setup — see Phase 0 Round 2 above. `PromptBuilder.swift` rewritten in Indonesian (4 real tasks, not the old `summary`/`overview`); new `ServerOpenRouter.swift` (non-streaming, mirrors `_shared/llm.ts`) alongside the untouched `ServerGemini.swift` (kept as the Phase 0 Round 1 historical artifact). This is still POC-level — no Supabase auth, no guided-journaling flow, no real app UI for these tasks. Full client build is Phase 2, not started.
- **Phase 2–4**: not started.

## Phases

### Phase 1 — Backend foundation
- ✅ Schema: `supabase/migrations/20260814000001_initial_schema.sql` — all 12 tables + 2 vocabulary lookup tables, `valence_classification` generated column, vocabulary validated by trigger (not a CHECK constraint — Postgres CHECK can't reference another table).
- ✅ RLS: `supabase/migrations/20260814000002_rls_policies.sql` — role-restricted per [ADR-0005](docs/adr/0005-child-feed-only-data-access.md), `create_family()` RPC (SECURITY DEFINER — the only way a parent profile gets created), a privilege-escalation trigger blocking `family_id`/`role` changes via UPDATE. Two real bugs caught and fixed during self-review before this was shown to the user: an overly-permissive direct-INSERT policy on `profiles` (would've let anyone self-assign `role='parent'` into any family), and the same class of issue on `invites` (client-suppliable token).
- ✅ DB webhooks as code (not dashboard config): `supabase/migrations/20260814000003_webhooks.sql`. Its original `app.settings.*` GUC approach hit a real permission wall on Supabase's managed Postgres (confirmed live, 2026-08-14: `alter database ... set` needs true superuser, which the `postgres` role doesn't have there) — fixed in `20260814000004_fix_webhook_secrets.sql` using **Supabase Vault** instead, which is the documented pattern for this exact problem.
- ✅ All 8 Edge Functions in `supabase/functions/`: `check-log-context`, `generate-how-to-react`, `send-how-to-react-push`, `send-crisis-alert-push`, `generate-overview`, `generate-reflection`, `send-family-invite`, `accept-family-invite`. Shared code in `supabase/functions/_shared/` (OpenRouter LLM client — [ADR-0010](docs/adr/0010-openrouter-llm-gateway.md), Indonesian prompts, APNs JWT signing + push, static crisis resource card).
- Auth wired up (Sign in with Apple, default recommendation — confirm with user before implementing) — not yet configured in `supabase/config.toml` beyond a disabled placeholder.
- Define `EmotionKind`/`EmotionLabel`/`EmotionAssociation` as plain Swift enums that copy Apple's HealthKit State-of-Mind vocabulary (values only) — **no HealthKit framework import**, per user decision (see [ARCHITECTURE.md §3](ARCHITECTURE.md#3-data-model-postgres)). Not started — this is client-side (iOS), Phase 1's backend half is done, this piece isn't.
- Supabase project region: not re-confirmed as Singapore for the live project — worth checking in the dashboard.

#### Deployment status — live project `asjznymcuyzafodpkmgg`

**Supabase** — done, 2026-08-14
- [x] Project created, CLI installed (`brew install supabase/tap/supabase`), logged in via personal access token, linked
- [x] All 4 migrations applied (`supabase migration list` confirms local/remote match)
- [x] Vault secrets set: `edge_functions_base_url`, `edge_function_service_role_key` (see `20260814000004_fix_webhook_secrets.sql`)
- [x] All 8 Edge Functions deployed (`supabase functions deploy --use-api` — no local Docker in this environment), confirmed `ACTIVE` via `supabase functions list`

**OpenRouter** ([ADR-0010](docs/adr/0010-openrouter-llm-gateway.md)) — done, 2026-08-14/15
- [x] `OPENROUTER_API_KEY` set
- [x] All 4 LLM-calling functions default to **free-tier** models (user decision) — `nvidia/nemotron-nano-9b-v2:free` for all four tasks, including crisis-signal detection in `check-log-context`, after empirically testing all 5 free structured-output-capable models and finding it was the only one that reliably works (see ADR-0010's model table for what failed and why)
- [x] `maxOutputTokens` recalibrated per call site (4000/3000/6000/6000) after finding the free model needs real headroom for its reasoning-token overhead, or it truncates before producing valid JSON
- [x] Redeployed all 4 affected functions with the final config
- [ ] **Not yet mitigated**: free-tier rate limits / shared-pool 429s have no retry or fallback; `check-log-context` fail-open-vs-fail-closed behavior on an LLM error is undecided — flagged as blocking before real launch in ADR-0010's Action Items
- [ ] Optionally override per-task models later: `OPENROUTER_MODEL_EXTRACTION`, `OPENROUTER_MODEL_HOW_TO_REACT`, `OPENROUTER_MODEL_OVERVIEW`, `OPENROUTER_MODEL_REFLECTION`

**Apple Push Notifications** ([ARCHITECTURE.md §5](ARCHITECTURE.md#5-notifications-apns))
- [ ] An APNs Auth Key (`.p8`) from the Apple Developer portal, plus its Key ID and your Team ID
- [ ] Set as secrets: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_PRIVATE_KEY` (full `.p8` contents), `APNS_ENV` (`sandbox` until the app ships to TestFlight/App Store, then `production`)

**Auth** ([ARCHITECTURE.md §7](ARCHITECTURE.md#7-open-non-blocking-items) — not yet confirmed)
- [ ] Confirm Sign in with Apple as the auth provider (default assumption) — if so, a Services ID + key from Apple Developer, configured in Supabase Auth
- [ ] `EMOTIONPOC_APP_REDIRECT_URL` — the universal link / custom URL scheme that brings a child back into the app after clicking the invite email (`send-family-invite`, [ARCHITECTURE.md §3b](ARCHITECTURE.md#3b-parentchild-pairing--email-invite)) — needs the iOS app's associated domain / URL scheme registered first

**iOS project**
- [ ] Apple Developer account + bundle ID registered, App Group entitlement for the widget ([ARCHITECTURE.md §3c](ARCHITECTURE.md#3c-home-screen-widget-parent--overview--tip-glance)), push notification entitlement

**Credential hygiene** — two secrets were pasted directly into chat during setup (2026-08-14) rather than entered somewhere that never surfaces them in a transcript: the Postgres database password, and (as a side effect of `supabase projects api-keys` printing it unmasked even without `--reveal`) the legacy `service_role` JWT. Neither was written to any file in this repo, and the *new-format* `sb_secret_...` key was used for the actual Vault configuration instead of the legacy JWT — but both are still worth rotating as routine hygiene:
- [ ] Reset the database password (Dashboard → Settings → Database)
- [ ] Consider disabling the legacy `anon`/`service_role` JWT keys once everything's confirmed working on the new `sb_publishable_`/`sb_secret_` keys (Dashboard → Settings → API)

None of this blocks continuing to write iOS client code (Phase 2) against the schema/API surface already defined — it only blocks actually deploying/testing the backend live.

#### iOS POC extension (2026-08-15) — Round 2 benchmark, not Phase 2 client work

User decision: pause backend work, extend the existing `EmotionPOC`/`BenchmarkCLI` POC (not start the real Phase 2 client) to validate the *actual* production setup — OpenRouter + Indonesian prompts — using dummy data, before building the real app around it. Findings are in [PERFORMANCE_COMPARISON.md §8](PERFORMANCE_COMPARISON.md#8-round-2-2026-08-15--openrouter-free-tier--prompt-bahasa-indonesia-4-task-produksi) and cross-linked from [ARCHITECTURE.md §2a](ARCHITECTURE.md#2a-llm-execution-mode--server-vs-on-device) and [§7](ARCHITECTURE.md#7-open-non-blocking-items).

- [x] `PromptBuilder.swift` rewritten: Indonesian prompts for the 4 real touchpoints (`extraction`, `howToReact`, `overview`, `reflection`), replacing the old `summary`/`overview` tasks that aren't part of the shipped product. This is the on-device reference spec (§2a) — kept in sync with `supabase/functions/_shared/prompts.ts` by hand, no shared source yet.
- [x] New `ServerOpenRouter.swift` — non-streaming client mirroring `_shared/llm.ts` exactly (production doesn't stream), default model matches the deployed backend's default. `ServerGemini.swift` (Round 1's client) left untouched — still the valid historical record for that round, not deleted.
- [x] `BenchmarkService.swift` / `CLIEntry.swift` updated for the new task set; `project.yml` updated with the new source file; build verified (`xcodebuild ... BenchmarkCLI` → `BUILD SUCCEEDED`).
- [x] Ran for real against dummy data, on-device + OpenRouter — see findings below.
- [x] **Latency fixed, shipped to production**: found Nemotron's `/no_think` system-prompt convention, cut all four tasks from ~6-36s to ~2-7s (0 reasoning tokens), also fixed `reflection`'s English-output bug as a side effect. Added to `_shared/llm.ts` + all four Edge Functions, redeployed. See [PERFORMANCE_COMPARISON.md §8c](PERFORMANCE_COMPARISON.md#8c-follow-up-2026-08-15-sama-hari--kedua-temuan-di-atas-ditindaklanjuti).
- [ ] **`check-log-context` crisis-detection reliability under `/no_think` is unverified** — only tested against non-crisis text; extraction looked less thorough without reasoning (more fields marked null). The deterministic keyword pre-filter (§2b) remains the primary safety net regardless, but this needs the same domain-expert review already required for the keyword list before shipping (ADR-0006).
- [ ] **`on_device` mode: workaround identified, not proven end-to-end.** Apple's `Translation` framework supports Indonesian on-device (unlike `FoundationModels`) — `OnDeviceTranslator.swift` proves the API (`TranslationSession.init(installedSource:target:)`) compiles and works outside SwiftUI, but the live test failed with `notInstalled`: the language pack isn't downloaded on this host, and there's no CLI-triggerable download path. Missing: a SwiftUI `.translationTask` download-permission flow (not built — `ContentView.swift` untouched), the full translate-in/translate-out pipeline, and selective JSON-value translation that doesn't mangle structural fields. Still need a product decision on whether to pursue this or hide `on_device` in Settings for now.

#### Real device retest (2026-08-15, same day) — physical iPhone via USB

User connected a physical iPhone (iOS 26.6) via USB and asked to retest — up to this point everything ran on the Mac host or (for Round 1) failed to load on Simulator. Also: user asked for the POC app to expose the on-device and server-side tests as two separate buttons instead of one combined run.

- [x] `ContentView.swift`: split into "Run On-Device" / "Run Server-Side" buttons with separate result sections (`OnDeviceResultRow` / `ServerResultRow`), reusing `BenchmarkService`/`ServerOpenRouter` unchanged.
- [x] Signed and deployed to the physical device: added `DEVELOPMENT_TEAM` to `project.yml`, required the user to sign into Xcode with their Apple ID first (an interactive auth step — not something to do on the user's behalf), then built/installed/launched via `xcodebuild -allowProvisioningUpdates` + `xcrun devicectl device install app` / `device process launch --console -e '{"OPENROUTER_API_KEY": "..."}' ... --autorun`.
- [x] **Both on-device blockers confirmed identical on real hardware** — same `unsupportedLanguageOrLocale` and `notInstalled` errors as the Mac host. Rules out "Mac/simulator-only quirk" as an explanation for either.
- [x] **New finding only visible on a real mobile network**: intermittent `NSURLErrorDomain -1005` ("connection lost") failures calling OpenRouter — not something a wired/stable dev-machine connection surfaces. Neither `ServerOpenRouter.swift` nor production's `_shared/llm.ts` retry on this yet.
- [x] **Bug found and fixed**: `--autorun` ran the server pass twice in one launch — SwiftUI `.task` re-fired on the real device in a way it hadn't during earlier testing. Fixed with an explicit `hasAutoRun` guard rather than relying on `.task` only running once.
- [ ] **Network retry logic not yet built** — flagged as needed before Phase 2, both client-side and in the Edge Functions.
- [ ] Full details: [PERFORMANCE_COMPARISON.md §8d](PERFORMANCE_COMPARISON.md#8d-real-device-retest-2026-08-15-sama-hari--iphone-fisik-via-usb-bukan-mac-hostsimulator).

#### Translation workaround confirmed working (2026-08-16)

User asked why on-device still fails "even after translating" — clarified this was a misunderstanding: translation had never actually succeeded yet (still `notInstalled`), and even if it had, nothing wired it into the actual generation pipeline. Fixed by adding the correct API path.

- [x] Added a SwiftUI `.translationTask(source:target:)`-driven "Test Translation" button to `ContentView.swift` — the only API path that can trigger Apple's language-pack download UI (`OnDeviceTranslator`'s direct init can't prompt, only use an already-installed pack).
- [x] User tapped it on the physical iPhone — no visible download dialog appeared, but the pack installed anyway (confirmed via a fresh app relaunch: both the SwiftUI and the plain `OnDeviceTranslator` calls succeeded, correct id→en translation).
- [x] **Workaround confirmed technically viable, not just theoretical.** See [PERFORMANCE_COMPARISON.md §8e](PERFORMANCE_COMPARISON.md#8e-translation-workaround--terbukti-jalan-setelah-language-pack-ke-download-2026-08-16).
- [ ] Still not built: the full translate-in → `FoundationModels`-in-English → translate-out pipeline; selective JSON-value translation (leave `relationship_signal.parent_concern: low|moderate|high` etc. untouched); a production UX plan for first-time language-pack download given no visible system prompt showed up in testing.
- [ ] This POC extension does **not** touch Supabase auth, the guided-journaling follow-up UI, or any real app screens — that's still Phase 2, not started.

### Phase 2 — MVP 1: Log entry + Relationship Overview
- iOS: child log entry form (emotion slider modeled on HealthKit State of Mind UX, but writing to our own backend only); parent Relationship Overview screen. **Child side is feed-only** (user decision, see [ARCHITECTURE.md §3](ARCHITECTURE.md#3-data-model-postgres)) — no overview/reflection/tip screen exists on the child side, and RLS backs this up at the data layer too, not just by omitting the UI.
- iOS: Settings toggle for `llm_mode` (server ↔ on-device) — **per-profile**, both parent and child each set their own (not a shared family setting).
- iOS: wire the existing on-device path (`BenchmarkService.swift`, `PromptBuilder.swift` from the POC) into the real app for `on_device` mode, alongside the new server-side (Edge Function) path — both must exist from the start, not staged in later.
- iOS: guided-journaling follow-up flow (see [ARCHITECTURE.md §3a](ARCHITECTURE.md#3a-guided-journaling--follow-up-question-flow)) — quick pick + free text, then mandatory follow-up questions for whichever of the 6 `log_context_field`s the LLM couldn't extract. Mode-aware per §2a.
- Edge Function `check-log-context` (server mode): extracts `log_context_field` values from the child's free text, returns missing fields.
- Rewrite `PromptBuilder`'s prompts (summary, overview, and the new extraction/how-to-react prompts) in **Bahasa Indonesia** — user decision, 2026-08-14. The English POC prompts are the reference structure (cautious-language rules, JSON shape), not literal text to translate mechanically. Applies to both the TS (server) and Swift (on-device) copies.
- Edge Function `generate-overview` (server mode; ports `PromptBuilder.overviewPrompt` to TS, calls OpenRouter — [ADR-0010](docs/adr/0010-openrouter-llm-gateway.md)).
- Edge Function `generate-how-to-react` (DB webhook on `emotion_logs` INSERT, fires once `context_complete = true`; no-ops in `on_device` mode) + `send-how-to-react-push` (DB webhook on `how_to_react_tips` INSERT, mode-agnostic APNs delivery).
- **Measure `check-log-context` / on-device extraction latency during build** for both modes — this is now a user-facing trade-off (§2a), not just an implementation fallback, so the UI should be honest about what the user is trading.
- **Guardrails (mandatory, not deferred — see [ARCHITECTURE.md §2b](ARCHITECTURE.md#2b-guardrails)):**
  - Client-side keyword pre-filter for crisis signals (self-harm/suicide) — deterministic, no network, always runs on child's entry text before anything else.
  - Secondary LLM crisis check folded into `check-log-context`'s extraction call, mode-aware like everything else in §2a.
  - `crisis_events` table + `send-crisis-alert-push` Edge Function delivering a static, verified resource card (SEJIWA 119 ext. 8, LISA Helpline 0811-3855-472, nearest Puskesmas/ER) — never LLM-generated.
  - Explicit, specific consent screen for `server` mode (UU PDP requires this separately from general ToS, since it's when child mental-health data reaches a third party).
  - "Report a concerning result" action on LLM-generated output (PP Tunas complaint-mechanism requirement) — reviewer/SLA not yet designed, flagged as open item.
  - Real keyword list needs a domain-expert pass before ship — the ones in ARCHITECTURE.md are illustrative only.

### Phase 3 — MVP 2: Reflection Recommendations
- New prompt: recommendation-oriented (sibling of `overviewPrompt`, same cautious-language rules).
- Edge Function `generate-reflection`.
- iOS: "Recommendations to Reflect" screen.

### Phase 4 — Home-screen widget (parent — overview + tip glance)
See [ARCHITECTURE.md §3c](ARCHITECTURE.md#3c-home-screen-widget-parent--overview--tip-glance). Read-only, parent-side only, scope narrowed 2026-08-14 (no quick-log widget for now). Friction-reduction on top of Phase 2/3's core flows, not foundational — sequenced after MVP1/MVP2 land.

- New `WidgetKit` extension target — no `AppIntents` needed, since there's no action for the widget to perform, only display.
- App Group (plain shared storage, e.g. `UserDefaults(suiteName:)` — not Keychain, no auth crosses this boundary) so the main app can write a small display cache (latest tip text, latest overview headline) for the widget's `TimelineProvider` to read. The widget extension never talks to Supabase directly.
- Main app calls `WidgetCenter.shared.reloadTimelines(ofKind:)` right after writing fresh `overviews` or `how_to_react_tips` data to the cache.
- `send-how-to-react-push` payload carries `content-available: 1` alongside the visible alert, so the app can refresh the widget cache even when not foregrounded — best-effort per iOS's own background-push throttling, not guaranteed-instant.
- Widget layout (which size shows what) is a UI detail, not decided, not blocking.

### Phase 5 — Deferred / future work
Not built now — explicitly scoped out for MVP speed, captured here so it isn't forgotten:

- **Trusted-source grounding (RAG) for "how to react" tips.** MVP ships with plain LLM generation, no citation/grounding to real parenting sources. Before this becomes a "trusted sources" feature (not just a generative guess), needs: a curated knowledge base or ingestion pipeline (should be Indonesian-language / Indonesia-context sources, e.g. IDAI or local child-psychology references, not generic Western parenting content — target users are Indonesian), a retrieval step in `generate-how-to-react`, and citations surfaced in the UI. **User decision (2026-08-14): ship ungrounded LLM first, revisit RAG after MVP1/2 land.**
- **Full compliance/legal review** for storing a minor's emotional/mental-health data against **UU PDP (Law 27/2022)**, **PP Tunas (PP 17/2025)** + Permen Komdigi 9/2026 (effective 2026-03-28), and **SE Menkominfo 9/2023** (AI ethics) — see [ARCHITECTURE.md §2b](ARCHITECTURE.md#2b-guardrails) for what's already researched and mandatory-for-MVP1 vs. what still needs a proper legal pass. Acceptable to defer the *full* review for a personal/beta build, must happen before any public launch — but the guardrail *implementation* itself (crisis detection, consent, complaint mechanism) is not deferred, it's in Phase 2.
- **Android / cross-platform** — iOS only for now.

## Open decisions

Tracked in one place only — **[ARCHITECTURE.md §7](ARCHITECTURE.md#7-open-non-blocking-items)** — not duplicated here. This list drifted out of sync with that one at least once already (caught during the 2026-08-14 architecture review); don't recreate a second copy. If a Phase item above depends on one of those open items, link to §7 rather than restating it.
- Widget layout (which size family shows what): not decided.
