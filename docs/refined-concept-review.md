# Refined Product Concept — Review Draft

**Status: draft for review, not yet integrated.** This is a synthesis of `refine.md` (theory-of-change research, 2026-08-24) against the existing [ARCHITECTURE.md](../ARCHITECTURE.md)/[PLAN.md](../PLAN.md), plus the decisions made while reviewing it. Nothing here is authoritative yet — once approved, its content gets distributed into ARCHITECTURE.md's actual sections and new ADRs (per this repo's "one fact, one place" rule), not kept as a permanent parallel doc.

---

## 1. What's actually changing

The current architecture is a data-pipeline spec: child logs → LLM synthesizes → parent reads. It doesn't say *why* that should change behavior. `refine.md` supplies the missing theory and one structural mechanism the current design doesn't have. Decisions made so far:

| Question | Decision |
|---|---|
| Bidirectional gap-surfacing (parent log vs child log as two independent signals) | **Yes — adopt.** |
| Weekly output shape: stay descriptive (current headline/summary/patterns/key_insight) or shift to tactical/prescriptive coaching | **Stay as-is.** Descriptive synthesis, not a rewrite into `refine.md`'s more directive coaching format. |
| Solo-parent entry point momentum gate ("7-day streak" before auto-nudge) | **Dropped.** Single rhythm: generate the summary once a week, period — no separate gamification mechanic. |
| Guided journaling follow-up flow (§3a — FEELING/TRIGGER/PERCEIVED_CAUSE/etc.) | **Unchanged.** Keep as designed, regardless of `refine.md`'s "not an awareness tool" framing. |

---

## 2. The theory (from `refine.md`, condensed)

**Problem**: kids don't withhold disclosure because they lack self-awareness — they withhold because they've already simulated the parent's likely reaction and conclude disclosure is futile (Smetana's *perceived futility*). This is an **execution gap**, not a comprehension gap.

**Why awareness alone doesn't fix it** (the "why does an app even help" question):
1. Insight lives in the prefrontal cortex; conflict triggers the amygdala, which overrides it in the moment (Caughlin & Ramey's demand-withdraw loop — high-power-figure paralinguistic dominance reads as threat, blood flow shifts away from the region where the insight is stored).
2. The problem is a self-reinforcing *structural loop* (demand → withdraw → more demand), not a personal trait either side can just decide out of.
3. Parent's and child's moments of clarity don't happen at the same time — a kid's 11pm resolve to open up and a parent's post-conflict remorse never meet in real time.
4. One side's private realization changes nothing without the other side seeing concrete evidence of different behavior.

**Mechanism**: move the *first* intervention point to an async, tap-based, private channel — outside the window where amygdala hijack can occur — so change starts without either side needing to be "brave" face-to-face first.

**Supporting frameworks**: Self-Determination Theory (autonomy/competence/relatedness — perspective-taking, providing rationale, non-controlling language), Family Communication Patterns Theory (conversation orientation, but power imbalance persists even in high-conversation families), Brown & Levinson politeness theory (face-threatening acts), Hofstede's Power Distance Index (Indonesia = 78 — this isn't just an individual trait, it's culturally structural).

---

## 3. Target user (narrowed)

**Not** a child who hasn't yet identified their own feelings or their family's patterns — this app is not an awareness-building tool for that gap. Target user has *already* connected the dots on both their own state and the family dynamic; the gap is that knowing doesn't translate into saying, in the moment, face to face.

*(Kept explicitly separate from the guided-journaling decision above: §3a stays, but its purpose is structured-context-extraction for the LLM prompts, not "help the child discover their feelings" — worth being precise about that distinction if this framing gets written into ARCHITECTURE.md, so the two don't read as contradictory.)*

---

## 4. Two entry points

**Option 1 — parent invites child directly.** Same shape as today's email-invite pairing (§3b unchanged). Both sides log asynchronously from day one.

**Option 2 — parent starts solo.** Parent uses the app alone, no child awareness/consent needed to begin:
- Parent logs their own daily reflection + answers guided prompts designed to provoke perspective-taking (e.g. "Think about a time this week your child was quiet. What do you think they were feeling?").
- LLM acts as a **private coach** on the parent's own entries only — surfaces authoritarian-leaning patterns, builds emotional vocabulary, introduces autonomy-supportive concepts — before the child is ever involved.
- After the parent's **first weekly summary** (not a streak), the app offers to generate an invite — and the invite text itself is LLM-generated, not parent-written, specifically so the demand-tone pattern doesn't leak into the one message that matters most for getting the child to say yes.
- Child accepts → converges into the same weekly cycle as Option 1.

---

## 5. Weekly cycle (core mechanic)

1. Both sides log during the week (child: existing emotion-log flow, unchanged, §3a intact; parent: their own daily reflection entries — see open question below on what this needs to look like structurally).
2. Once a week, the LLM synthesizes **both logs together**, not child-data-primary/parent-context-secondary as today. Parent's private entries are an equally-weighted input, not background color.
3. This is what makes the LLM an **objective third party** — it can surface pragmatic incongruence (parent logs "I gave helpful guidance," child logs "felt like a lecture") from the data itself, without either side having to notice or admit it first.
4. Output stays in the **current descriptive shape** (headline/summary/patterns/relationship_signal/key_insight) per the decision above — not rewritten into a more directive "say this instead" coaching format.
5. Parent applies whatever they take from it in their next real interaction.

---

## 6. Open questions this raises for the actual architecture

Flagging these now rather than silently deciding them — they're real implementation forks:

- **Parent-side data shape.** Today's `parent_interactions`/`parent_reflection_logs` are lightweight, freeform notes — sufficient as *context* for a child-centric overview, but the bidirectional-comparison mechanic needs the parent's entries to be a comparably-structured weekly signal (something closer to the child's mood-log shape) for the LLM to meaningfully contrast the two. Worth deciding whether that means a new parent-facing daily/weekly entry flow, or just changing how the existing tables get used in the prompt.
- **Cadence trigger.** Current `generate-overview`/`generate-reflection` are on-demand (parent taps a button). "Once a week" implies a scheduled trigger instead (or in addition) — likely `pg_cron` inside Supabase calling the Edge Function on a schedule, not purely client-initiated. New infra piece, not free.
- **Solo-mode's private-coach output** — does this get stored in the existing `overviews` table (no `family_id`-paired child yet, so the shape doesn't quite fit), or does it need its own table until the child joins?
- **What happens if one side didn't log that week?** Does the synthesis degrade gracefully to a solo reflection, skip entirely, or something else?
- **Invite-nudge generation** — new LLM touchpoint (drafts the invite message), needs its own prompt and probably its own guardrail pass (it's outbound, parent-approved-before-send presumably, not auto-sent silently).

---

## 7. What's explicitly unaffected

- Crisis detection/escalation (§2b) — `refine.md` doesn't touch safety-critical content at all; assume unchanged underneath whatever else changes here.
- Per-profile `on_device`/`server` toggle (§2a) — orthogonal, though solo-mode's private journaling is arguably the *most* privacy-sensitive content in the whole product, worth keeping in mind when this gets built out (on-device might matter more there than anywhere else).
- Compliance grounding (UU PDP, PP Tunas, SE Menkominfo 9/2023) — unaffected.

---

## 8. Sources (from `refine.md`)

Smetana (adolescent disclosure, perceived futility) · Caughlin & Ramey 2005 (demand-withdraw) · Brown & Levinson 1987 (politeness theory) · Self-Determination Theory (Deci & Ryan) · Family Communication Patterns Theory · The Legacy Project, Cornell University · Hofstede Power Distance Index (Indonesia = 78)
