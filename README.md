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
