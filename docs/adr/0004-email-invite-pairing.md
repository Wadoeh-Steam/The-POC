# ADR-0004: Parent↔child pairing via email invite, not Apple Family Sharing

**Status:** Accepted
**Date:** 2026-08-14
**Deciders:** radityaaydin

## Context

The app needs to link a parent account and a child account into one `family` so a parent can see the overview/reflection built from their specific child's data. The obvious platform-native option on iOS is Apple's Family Sharing / Screen Time account graph. The user explicitly ruled this out: "app ini bukan family sharing."

## Decision

Pairing is a plain **email invite**: parent enters the child's email, the child receives an emailed link, completes their own auth, and gets linked to the family. `families`/`profiles` are entirely our own database construct, independent of any Apple account-linking API.

## Options Considered

### Option A: Email invite (chosen)
**Pros:** No dependency on Apple's Family Sharing APIs or account graph; works regardless of whether the family already uses Apple's own Family Sharing for other things; recommend Supabase Auth's built-in `admin.inviteUserByEmail()` so no separate transactional-email vendor is needed.
**Cons:** Requires the child to have their own email address to receive the invite — open question (see [ARCHITECTURE.md §7](../../ARCHITECTURE.md#7-open-non-blocking-items)) whether that's always realistic for a minor, ties into PP Tunas age-appropriate account creation ([ADR-0006](0006-guardrails-indonesian-compliance-and-crisis-safety.md)).

### Option B: Apple Family Sharing / Screen Time
**Pros:** Native to iOS, no separate invite flow to build, parent likely already has a Family Sharing group set up.
**Cons:** Explicitly rejected by user — couples the product's account model to Apple's family graph, which isn't this product's data model (a `family` here is specifically parent+child around emotional data, not Apple's broader household concept).

### Option C: In-app pairing code / QR
**Pros:** No email needed, works well for same-room pairing.
**Cons:** Not chosen for now — email invite is simpler to ship first and doesn't require both devices to be physically together at pairing time.

## Trade-off Analysis

Email invite is the lowest-friction option that doesn't require adopting Apple's family-account model. The main open cost is the "does a child have their own email" question, which is a real product/compliance question, not an engineering one.

## Consequences

- Easier: `families`/`profiles` stay a clean, portable data model, not entangled with Apple's account graph.
- Harder: invite flow (token, expiry, accept endpoint) is bespoke, not reusing an existing Apple mechanism.
- Revisit when: invite friction (child needing their own email/Apple ID) turns out to be a real adoption blocker — see [ARCHITECTURE.md §6](../../ARCHITECTURE.md#6-trade-offs-made).

## Action Items

1. [x] Phase 1: `invites` table + RLS (`supabase/migrations/`), `send-family-invite` + `accept-family-invite` Edge Functions (`supabase/functions/`) — scaffolded 2026-08-14. Token is minted server-side in `send-family-invite` (`crypto.randomUUID()`), not client-supplied — an earlier draft had a direct client-INSERT RLS policy on `invites`, corrected during implementation since that would mean trusting the client's RNG for something this security-sensitive. See the "Invite token generation" row in [ARCHITECTURE.md §6](../../ARCHITECTURE.md#6-trade-offs-made).
2. [ ] Decide invite token expiry duration (currently a 7-day placeholder in `send-family-invite`, not finalized), resend/revoke capability
3. [ ] Decide whether a child needs their own email/Apple ID before Phase 1 ships
4. [ ] Configure `EMOTIONPOC_APP_REDIRECT_URL` (universal link / custom URL scheme) so the invite email's redirect lands back in the app, not a browser
