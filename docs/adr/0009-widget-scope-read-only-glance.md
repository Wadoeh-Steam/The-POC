# ADR-0009: Home-screen widget scope — read-only parent glance, no AppIntents

**Status:** Accepted
**Date:** 2026-08-14
**Deciders:** radityaaydin

## Context

Widgets were initially explored for three purposes: an interactive child quick-log widget, an interactive parent quick-log widget, and a read-only parent overview/tip glance widget. The interactive versions would need `AppIntents` and a shared-Keychain App Group (to let the widget extension write authenticated data). The user then narrowed scope: for now, widgets are parent-side only, showing the overview and the how-to-react tip after the child logs — no quick-log widgets. Full design in [ARCHITECTURE.md §3c](../../ARCHITECTURE.md#3c-home-screen-widget-parent--overview--tip-glance).

## Decision

One `WidgetKit` extension, read-only, parent-side: shows the latest Relationship Overview headline and the latest how-to-react tip. No `AppIntents`, no interactive quick-log. The main app writes a small display cache into a plain (non-Keychain) App Group container for the widget's `TimelineProvider` to read — the widget extension never talks to Supabase directly. `send-how-to-react-push` carries `content-available: 1` alongside the visible alert so the app can refresh that cache even when not foregrounded.

## Options Considered

### Option A: Read-only parent glance only (chosen, current scope)
**Pros:** No `AppIntents` needed at all; no shared-Keychain auth-sharing complexity — a plain shared cache suffices since nothing writes from the widget process.
**Cons:** Doesn't reduce logging friction for the child, which was part of the original motivation for exploring widgets at all.

### Option B: Add interactive child/parent quick-log widgets (deferred, not rejected)
**Pros:** Directly reduces friction on the "feeding data" motion central to the product.
**Cons:** Real added complexity: `AppIntents`, shared-Keychain App Group, and a genuine data-model consequence — a widget-submitted log would necessarily be quick-pick-only (no room for the guided-journaling follow-up flow, [ADR-0008](0008-guided-journaling-extraction-flow.md)), producing an incomplete (`context_complete = false`) entry that needs its own "unresolved follow-ups" UI, and a crisis-detection gap (§2b's keyword layer has no free text to scan on a quick-pick-only entry). None of this is designed yet — deliberately out of scope for now, not discarded.

## Trade-off Analysis

Starting with the read-only widget ships value (parents get an at-a-glance surface) without pulling in the AppIntents/App-Group-auth complexity or the guided-journaling/crisis-detection consequences that the quick-log widgets would introduce. If quick-log widgets get picked back up later, [ARCHITECTURE.md §3c](../../ARCHITECTURE.md#3c-home-screen-widget-parent--overview--tip-glance) already has the exploratory design notes preserved.

## Consequences

- Easier: no `AppIntents`, no shared-Keychain complexity, simpler App Review surface.
- Harder: none new — this is a scope reduction, not an added constraint.
- Revisit when: friction on the "child feeds data" flow turns out to need addressing beyond the guided-journaling flow already in place.

## Action Items

1. [ ] Phase 4: build the read-only widget extension + App Group cache + `WidgetCenter.shared.reloadTimelines` wiring
2. [ ] If quick-log widgets get revisited later, start from the exploratory notes in [ARCHITECTURE.md §3c](../../ARCHITECTURE.md#3c-home-screen-widget-parent--overview--tip-glance) rather than redesigning from scratch
