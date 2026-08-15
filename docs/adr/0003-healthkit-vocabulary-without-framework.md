# ADR-0003: Copy HealthKit's State of Mind vocabulary, don't import the framework

**Status:** Accepted
**Date:** 2026-08-14
**Deciders:** radityaaydin

## Context

The child's emotion-logging slider was designed to feel like Apple's real HealthKit "State of Mind" feature — and the dummy dataset the user supplied uses field names (`kind: "dailyMood"/"momentaryEmotion"`, labels like `frustrated`/`hopeful`, associations like `education`/`family`) that are literally Apple's `HKStateOfMind.Kind`/`.Label`/`.Association` enum values. The question was whether to actually integrate with HealthKit (write real `HKStateOfMind` samples) or just reuse the same string vocabulary.

Real HealthKit integration would mean: HealthKit entitlements, on-device-only data access (backend can't query HealthKit directly — the client would need to be a sync worker via `HKObserverQuery`), and elevated App Store review scrutiny since State of Mind is a mental-health-category HealthKit data type.

## Decision

**Copy the vocabulary, skip the framework.** `kind`/`labels`/`associations` are plain Swift enums (client-side) and `text` + check-constraint columns (Postgres) that happen to share Apple's exact string values. No `HealthKit` import, no entitlement, no `HKStateOfMind` writes.

## Options Considered

### Option A: Vocabulary only, no HealthKit (chosen)
**Pros:** Familiar slider UX and label set for users, zero HealthKit entitlement/App Review overhead, backend can query the data directly (it's just our own Postgres rows, not a client-only store).
**Cons:** No cross-app sync with Apple Health — a family's HealthKit-logged moods elsewhere on the device aren't visible to this app, and vice versa.

### Option B: Real HealthKit integration
**Pros:** Interop with the Health app and other HealthKit-aware apps; Apple's own polished logging UI available for free.
**Cons:** Backend can't read HealthKit directly (on-device-only store) — would need a client-side sync worker; mental-health-category HealthKit data draws more App Store scrutiny; adds real implementation complexity for a beta build that doesn't need the interop yet.

## Trade-off Analysis

The interop benefit of Option B isn't needed for the current product (this app is the primary place families log this data, not a secondary view onto Health app data). The cost — entitlements, sync worker, App Review exposure — isn't worth paying for a beta.

## Consequences

- Easier: full backend query access to emotion data; simpler App Review path; simpler client code (no HealthKit authorization flow).
- Harder: no HealthKit ecosystem interop; the MVP label/association set is only what's in the dummy dataset (`calm`, `hopeful`, `frustrated`, `annoyed`, `lonely`, `sad`, `worried`, `proud`, `excited`, `stressed`, `overwhelmed`, `irritated`, `amused`, `happy`, `discouraged`, `indifferent` / `family`, `education`, `friends`, `tasks`) — expanding to Apple's full published list is separate future work, not a guessed-and-hardcoded list.
- Revisit when: there's a concrete reason to want cross-app sync with Apple Health.

## Action Items

1. [ ] Phase 1: define `EmotionKind`/`EmotionLabel`/`EmotionAssociation` Swift enums + matching Postgres check constraints
