# Phase 2 Client Build — Draft Tickets (6 engineers)

**Status: draft for review, not filed yet.** Based on the design mockups reviewed 2026-08-24 (Overview/Advice/Calendar/onboarding screens, several copy variants, plus a follow-up pass with annotated flow details). Ties into [ARCHITECTURE.md](../ARCHITECTURE.md) §3a/§4 and [PLAN.md](../PLAN.md) Phase 2/3. Split for 6 engineers working roughly in parallel — dependencies noted where one blocks another.

**⚠️ Needs an architecture decision before Ticket 2 starts for real**: the mockups describe the guided-journal flow as **3 fixed main questions, each with at most 1 LLM-generated followup if needed** — this is a different shape from `ARCHITECTURE.md` §3a's current design (6-field enum — FEELING/TRIGGER/PERCEIVED_CAUSE/PRIOR_EFFORT/FUTURE_PLAN/EXPECTED_OUTCOME — extracted from free text, one follow-up per missing field). Not resolved in this doc; flagging so Ticket 2 doesn't get built against a spec that's already stale. §3a needs updating to match, once confirmed.

Not yet decided and worth resolving before filing for real: the app/section naming (mockups show three candidates — **Gema**, **Beranda**, **Ringkasan** — for what's currently just "Overview" in the architecture docs). Whichever ticket owns the Overview screen should treat naming as an input, not a blocker — build against "Overview" and swap the string once decided.

---

## Ticket 1 — Log Input System (shared component: valence/label/association)

**Screens**: `emotion picker (valence)`, `emotion picker (label)`, `emotion picker (association)`, plus the color treatment visible on the dashboard detail card

**Scope**: this is explicitly labeled "log input system" across all three picker screens in the mockup — treat it as one reusable component set, not three one-off screens:
- Fixed vocab lists (valence/label/association) with a matching emoji per value (HealthKit State of Mind vocabulary, per [ARCHITECTURE.md §3](../ARCHITECTURE.md#3-data-model-postgres)) — multi-select on label/association grids, "Show more" for the full list vs the MVP subset.
- **Valence → dynamic linear gradient**: the selected valence emoji drives a background gradient color, and this needs to be a reusable modifier/style, not styling local to this one flow — it's reused on the child dashboard's log-detail card (Ticket 3) and the calendar's tap-to-detail view (Ticket 6).
- Additional-context free-text field (60 char cap shown in mockup) on the association step.

**Depends on**: nothing — start immediately.

**Blocks**: Ticket 2 (needs the picker output as input), Ticket 3 and Ticket 6 (both reuse the gradient/color system for detail views). Given two other tickets depend on this, **prioritize starting this one first**, or staff it with whoever's fastest to unblock the others.

**Out of scope**: the `emotion_logs` INSERT — that's Ticket 2, gated on the guided-journal flow completing (§3a: row only saves once `context_complete = true`, except the crisis early-save exception).

---

## Ticket 2 — Guided journal flow (3 main questions + conditional LLM followup) + submit

**Screens**: `prompt 1`, `prompt 2`, `prompt 3`, `preview`, `prompt...copy 2` (post-submit message)

**Scope** (per the flow description, supersedes what's currently in §3a — see the callout above):
- 3 fixed main journal questions (mockup copy is placeholder — "Kasih paham emak" etc. are not final strings, need real copy before ship).
- Each main question can get **at most one** LLM-generated followup, shown only if the LLM decides that answer needs more context — not a fixed second question, and not the previous per-field up-to-6 model.
- **Preview screen** before submit — shows all question/answer pairs (including any followups) for the child to review.
- **Post-submit confirmation** — static message screen ("Message sent to your parent...").
- Still wires into `check-log-context` Edge Function (server mode) / local `SystemLanguageModel` (on-device, §2a) for the followup-generation decision and any crisis-signal check — same mode-aware branching as before, just a different question shape underneath.

**Depends on**: Ticket 1 (quick-pick data feeds into this flow). Architecture decision above needs to land before backend prompt work starts, though client-side screen-building can proceed against placeholder logic in the meantime.

**Watch for**: same latency-UX concern as before (`server` vs `on_device` felt directly here, §2a) — now compounded by needing a live decision ("does this answer need a followup?") per question, not just a one-shot extraction call. Crisis early-save exception still needs to not break mid-flow.

---

## Ticket 3 — Child dashboard + log detail view

**Screens**: `dashboard`, `dashboard` (filled-in variant), `child log detail`

**Scope**: child's own view of their logged entries — weekly mood summary line, calendar with a mood-emoji per logged day, recent-entries list. Tapping an entry opens a **detail view** of that log, background/border colored by the entry's valence (reuses Ticket 1's gradient system — don't rebuild it locally). This is the child looking at **their own data only** — not overview/reflection content, which stays parent-only per the hard RLS boundary in ARCHITECTURE.md §3. Worth double-checking against that boundary explicitly during build.

**Depends on**: Ticket 1 (gradient/color component), Ticket 2 (real `emotion_logs` rows to render).

---

## Ticket 4 — Parent Overview screen + weekly card

**Screens**: `Overview`, `Overview - Scroll`, `Overview Copy` / `Copy 2` / `Copy 3` / `Copy 4`

**Scope**: "This Week Summary" card — Pola Tantangan headline, per-topic breakdown (Pendidikan/Teman-teman/Keluarga), gap-pemahaman warning, italicized key-insight box, "See Advice" CTA. The Copy 4 variant additionally shows a **scrollable history of past weekly cards** grouped by month — decide whether that's in this ticket's scope or belongs with Ticket 6 (Calendar's Weekly Summaries tab covers similar ground; don't build the same list twice).

**Depends on**: `generate-overview` Edge Function (exists, deployed) for the data shape. If the [refined-concept-review.md](refined-concept-review.md) bidirectional-synthesis decision lands before this ships, the prompt/data shape changes but the card UI shouldn't need to — worth building against the current `overviews` shape now rather than blocking on that decision.

---

## Ticket 5 — Parent Advice / Reflection screen

**Screens**: `Advice`, `Detailed Page Copy`, `Detailed...ge Copy 2` (both variants)

**Scope**: the reflection recommendations screen — same pattern breakdown as Overview, plus a highlighted **suggested-dialogue quote card** ("Sepertinya Maya baru ngerasa frustrasi...") and a numbered "Rekomendasi Refleksi" list. The bolded-keyword text in the summary (e.g. "**stres akademik**", "**kekhawatiran sosial**") and the quote-card pattern are **already built and tested** in this session's POC — `EmotionPOC/App/HumanReadable.swift`'s `QuoteAwareText`/markdown-bold rendering is the same mechanic, just needs porting from the POC's SwiftUI List-based layout into the real app's screen design. Worth this engineer skimming that file before starting — it'll save reinventing the parsing logic (splitting narrative text from a highlighted quote span, handling `**bold**` markers).

**Depends on**: `generate-reflection` Edge Function (exists, deployed). Ticket 4's card component, if the pattern-breakdown UI is meant to be shared between Overview and Advice rather than duplicated.

---

## Ticket 6 — Calendar (Daily Journals + Weekly Summaries)

**Screens**: `Calendar - V1 - Daily Journals`, `Calendar - V1...kly Summaries`, `Calendar - V2`, `Calendar - V2...iew Summary`

**Scope**: two competing concepts shown — **V1** (tab switcher between a month-grid "Daily Journals" view and a "Weekly Summaries" list) vs **V2** (simpler "Days logged: N" + "View summary" link, dots-on-calendar for logged days, drill into a detail sheet with Summary/View advice tabs). These read as alternatives, not both-in-scope — flag for a decision before filing, since building both wastes an engineer's sprint. Tapping a date on the calendar opens the detail history log for that day — reuse Ticket 3's log-detail view/gradient component rather than building a second one.

**Depends on**: Ticket 1 (gradient/color component), Ticket 3 (daily entries + detail view to reuse), Ticket 4 (weekly summaries).

---

## Open items to resolve before filing for real

- **Guided-journal flow shape** (3 questions + ≤1 LLM followup each) contradicts current `ARCHITECTURE.md` §3a — needs a real decision + doc update before Ticket 2 is fully spec'd.
- **V1 vs V2 Calendar** — pick one, don't build both.
- **App/section naming** — Gema / Beranda / Ringkasan / "Overview" — affects Ticket 4 and 6's copy, not their logic.
- **Overview history list** (Copy 4's scrollable past-weeks view) — Ticket 4 or Ticket 6, avoid duplicating.
- **Ticket 1 is now a cross-cutting dependency** for Tickets 2, 3, and 6 — sequence it first, or accept that those three can only build against a mock/stub of the gradient system until it lands.
- Ticket sizing assumes roughly even effort — Ticket 2 (guided journaling, now with per-question LLM decisions) is probably the heaviest; worth a gut-check once someone's actually scoped it, may need rebalancing against Ticket 5 or 6 (likely lighter).
