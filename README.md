# EmotionPOC

> ⚠️ **Status: exploration phase (Proof of Concept / POC), not a finished
> product.** Everything in this repository — docs, design decisions, code —
> can still change, and some of it may be reworked entirely before (or if)
> this moves into an actual build phase. Treat everything here as working
> notes and experiments, not final decisions.

## What is this?

EmotionPOC is an early-stage exploration of an app meant to help **parents
better understand how their children are feeling**. The child logs their
mood/feelings briefly (similar to a daily mood check-in), and the app tries
to summarize patterns across those entries for the parent — not by exposing
the child's private notes verbatim, but by giving a careful, non-judgmental
overview and gentle suggestions.

The target users are Indonesian families, so everything shown to parents is
written in Bahasa Indonesia.

## Why is it still called a "POC"?

There's no app yet that anyone can actually use day-to-day. What exists so
far is:

1. A **design** for how the system should work (what data is stored, who
   can see what, etc.)
2. **Experiments** on the riskiest part of that design — mainly, whether the
   AI should run on a server or directly on the phone, and which is faster
   / cheaper / better for privacy.
3. An **internal test harness** (not the real app) to compare those two
   approaches using sample data, not real users' data.

All of this is happening *before* committing to actually building the app,
so that big decisions (server vs on-device) are grounded in real
experiments instead of guesses.

## Progress so far

- ✅ System architecture written up (still subject to change)
- ✅ An experimental backend deployed to a private test environment — not
  public, no real users yet
- ✅ Compared running the AI on a server vs directly on-device — see the
  results below and in `PERFORMANCE_COMPARISON.md`
- ⬜ The actual iOS app people would use day-to-day **hasn't been built
  yet** — it's still only planned

## High-level comparison: server vs on-device

One of the main open questions was: should the AI features run on a server
(cloud), or directly on the phone (on-device)? Both were tested end-to-end
using the same 4 real product touchpoints and the same sample data, on a
physical iPhone.

| What's being tested | Server (cloud) | On-device (phone) |
|---|---|---|
| Reading a child's entry & checking for crisis signs | ~2.5–2.6 sec | ~1.8–2.7 sec |
| A quick tip for the parent | ~1.5 sec | ~1.1–1.4 sec |
| Summarizing patterns across several entries | ~6.4–7.8 sec | ~5.3–6.5 sec |
| Reflection suggestions for the parent | ~5.6–6.6 sec | ~6.6–9.0 sec |

*(Rough ranges from multiple test runs — not a rigorous benchmark; real-world
timing varies with network conditions and phone hardware.)*

**Takeaway:** neither option is a clear speed winner — they land in the same
ballpark, task by task. The more meaningful differences are elsewhere:

- **Server**: relies on internet access, has a small ongoing cost per
  request, sends data off the phone — but needs no setup and always uses
  the same AI model.
- **On-device**: free to run, keeps data on the phone (better for privacy),
  works offline — but the phone must download a one-time language pack
  first, and only supports Indonesian output through an extra
  translation step (Apple's on-device AI doesn't generate Indonesian
  directly yet — see `docs/adr/0002-per-profile-llm-execution-mode.md`).

Neither approach is confirmed as "the" final choice yet — this is exactly
the kind of evidence this POC phase exists to gather.

## Folder structure (for the curious — no need to understand the code)

| Folder/File | What's in it |
|---|---|
| `ARCHITECTURE.md` | Technical doc: how the system is designed to work |
| `PLAN.md` | Build plan & status of each piece |
| `PERFORMANCE_COMPARISON.md` | Detailed AI speed test results (server vs on-device) |
| `docs/adr/` | Notes on the reasoning behind major decisions |
| `EmotionPOC/` | Code for the internal test harness (not the final app) |
| `supabase/` | Code for the experimental backend (database, server functions) |

The documents above are written for a technical reader (developer) and may
be dense — this README is the one meant for a non-technical reader.

## How to run this locally

For anyone with Xcode who wants to try the test harness themselves:

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — this project's Xcode project file is generated, not checked in.
2. From the repo root, run:
   ```bash
   xcodegen generate
   ```
3. Open `EmotionPOC.xcodeproj` in Xcode, or build from the command line:
   ```bash
   xcodebuild -project EmotionPOC.xcodeproj -scheme EmotionPOC -destination 'generic/platform=iOS Simulator' build
   ```
4. The server-side comparison needs an OpenRouter API key at runtime
   (`OPENROUTER_API_KEY`) — **ask Radit for this**, it's not included in the
   repo on purpose (see the credential-hygiene notes in `PLAN.md`). Same
   goes for any Supabase project credentials if you want to run against the
   live backend instead of just the on-device path.
5. The on-device path also needs the phone/simulator to have the
   Indonesian↔English language pack installed once — the app has a button
   for that on first run.

## Using the backend (Edge Functions) directly

The 11 Edge Functions live in `supabase/functions/` and are deployed to the
shared test project `asjznymcuyzafodpkmgg` — the same instance the POC
harness above and the real iOS client (`ios-client` repo) both talk to,
there's only one backend. Full endpoint-by-endpoint description is
[ARCHITECTURE.md §4](ARCHITECTURE.md#4-api-surface); this section is just
the practical "how do I actually call one" — useful for testing a change
without going through the app UI at all.

**Secrets** (`supabase secrets set` / `--project-ref asjznymcuyzafodpkmgg`,
ask Radit for values — never put these in a repo file):
`OPENROUTER_API_KEY`, `REQUESTY_API_KEY`, `GEMINI_API_KEY`. Every LLM call
in this codebase goes through `_shared/llm.ts`'s `callLlmWithFallback()` —
cascades OpenRouter → Requesty → Gemini on any failure, one wall-clock
budget for the whole chain (not per-provider). If a function starts
returning 502s, check `supabase functions list --project-ref
asjznymcuyzafodpkmgg` deployed OK first, then suspect OpenRouter's 50
req/day free-tier cap before assuming a code bug — this has happened.

**Getting a test JWT** — none of the Edge Functions accept the
anon/publishable key alone, they all require a real signed-in user (they
call `auth.getUser()`). Sign in as an existing test user:

```bash
curl -X POST 'https://asjznymcuyzafodpkmgg.supabase.co/auth/v1/token?grant_type=password' \
  -H "apikey: <publishable_key>" \
  -H "Content-Type: application/json" \
  -d '{"email":"<test-user-email>","password":"<password>"}'
```

Take `access_token` from the response — it expires in 1 hour
(`expires_in: 3600`), re-run the above to get a fresh one. Need a test user
in the first place? Dashboard → Authentication → Users → **Add user** →
"Create new user" (check "Auto Confirm User") — then give that user a
`profiles` row (Table Editor or SQL Editor) with a `family_id` and
`role = 'parent'`, since most functions check that row, not just that
auth succeeded.

**Calling a function**:

```bash
curl -X POST 'https://asjznymcuyzafodpkmgg.supabase.co/functions/v1/select-parent-log-questions' \
  -H "apikey: <publishable_key>" \
  -H "Authorization: Bearer <access_token>" \
  -H "Content-Type: application/json" \
  -d '{"valence": 0.5, "valence_classification": "positive"}'
```

Same pattern for the other two be1 functions
(`evaluate-parent-log-followup` takes `{question_text, answer_text}`;
`submit-parent-log-entry` takes `{family_id, valence, labels,
associations, answers}` — see each function's `index.ts` for the exact
shape) and for the pre-existing ones (`generate-overview`/
`generate-reflection` take `{family_id}`, `check-log-context` takes
`{valence, labels, associations, journal}`).

**After a migration or function change**, from this repo's root:
```bash
supabase db push --project-ref asjznymcuyzafodpkmgg
supabase functions deploy <name> --project-ref asjznymcuyzafodpkmgg
```
`supabase migration list --project-ref asjznymcuyzafodpkmgg` shows
local-vs-remote drift before you push — if it reports a remote migration
version with no local file, stop and figure out where that came from
before proceeding (don't `migration repair` blind — it only edits the
tracking table, not the schema itself, see the git log around
2026-08-25 for a real instance of this).

## Things worth remembering

- All the experiments above use **sample (dummy) data**, not real families'
  data.
- The product direction, features, and even the technical approach **can
  still change at any time** — that's a normal part of this exploration
  phase.
- Nothing in the technical docs is guaranteed to be built exactly as
  written.

## About this repository

This repository — including its architecture docs, code, and this README —
was produced with the help of [Claude](https://www.anthropic.com/claude),
Anthropic's AI coding assistant, working alongside a human developer who
directed the work, reviewed the output, and made the product and technical
decisions. AI assistance was used throughout: system design, backend
implementation, and the benchmark testing described above.
