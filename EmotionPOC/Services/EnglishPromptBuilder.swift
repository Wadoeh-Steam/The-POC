import Foundation

/// English mirror of PromptBuilder.swift — exists *only* for the on-device
/// translation workaround (§2a): Apple Intelligence doesn't support
/// Indonesian generation, but does support English, so `on_device` mode
/// runs these English prompts and translates the result back to
/// Indonesian (OnDeviceTranslationPipeline.swift) instead of prompting in
/// Indonesian directly and failing with `unsupportedLanguageOrLocale`.
///
/// Not user-facing — a parent/child never sees this text, only the
/// Indonesian input/output around it. Keep the *shape* (JSON schema,
/// cautious-language rules) identical to PromptBuilder.swift's Indonesian
/// prompts, so translating the result doesn't change what's actually
/// being asked.
enum EnglishPromptBuilder {

    static func compactLog(_ log: EmotionLog, contextAnswers: [LogContextField: String] = [:]) -> String {
        var parts: [String] = [
            String(log.timestamp.prefix(10)),
            "mood=\(PromptBuilder.valenceClassification(log.healthkit.valence))",
        ]
        if !log.healthkit.labels.isEmpty {
            parts.append("labels=[\(log.healthkit.labels.joined(separator: ","))]")
        }
        if !log.healthkit.associations.isEmpty {
            parts.append("context=[\(log.healthkit.associations.joined(separator: ","))]")
        }
        if let journal = log.journal, !journal.isEmpty {
            parts.append("note=\"\(journal)\"")
        }
        for field in LogContextField.allCases {
            if let answer = contextAnswers[field] {
                parts.append("\(field.rawValue.lowercased())=\"\(answer)\"")
            }
        }
        return "- " + parts.joined(separator: " | ")
    }

    static func compactLogs(_ data: DummyDataset) -> String {
        data.emotionLogs.map { compactLog($0) }.joined(separator: "\n")
    }

    static func compactParentContext(_ data: DummyDataset) -> String {
        var lines: [String] = []
        for i in data.parentContext.recentInteractions {
            lines.append("- \(String(i.timestamp.prefix(10))) [\(i.topic)] \"\(i.interaction)\" (parent feels: \(i.parentEmotion))")
        }
        if !data.parentContext.parentLogs.isEmpty {
            lines.append("Parent reflection logs:")
            for p in data.parentContext.parentLogs {
                lines.append("- \(String(p.timestamp.prefix(10))) feels \(p.emotion): \"\(p.note)\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static let cautiousLanguageRule = """
    Use cautious language only: "may", "appears to", "a possible pattern is", "could indicate". \
    Never use: "has a disorder", "is depressed", "this proves that". \
    Do not diagnose. Do not blame either the child or the parent.
    """

    /// Kept in sync with PromptBuilder.swift's personalityRule, but
    /// deliberately DROPS the quoted-dialogue requirement that exists on
    /// the OpenRouter/backend side (no quoteRule here) — the on-device
    /// model couldn't reliably hold persona + addressee + quote-formatting
    /// + casual-tone + length all at once (5 rounds of live regressions,
    /// 2026-08-20: vocative-address bug → endearment bleeding into the
    /// whole answer → context-window overflow → whole-answer quote-wrap →
    /// single-quotes instead of double + addressing "both of you"
    /// together). Scoped down to just what this model can hold reliably:
    /// correct addressee and a warm tone, no forced quote structure.
    private static func personalityRule(childName: String) -> String {
        """
        You're a wise, warm, assertive 50s family companion — confident advice, not hedgy or clinical. Validate the PARENT's own difficulty too. Mention \(childName) naturally mid-sentence, NEVER as an opening address ("\(childName), ..."). You are speaking TO THE PARENT ONLY, ABOUT \(childName) — never to \(childName) directly, and never to "both of you" together.
        """
    }

    /// Kept in sync with PromptBuilder.swift's autonomySupportiveRule /
    /// prompts.ts's AUTONOMY_SUPPORTIVE_RULE_ID, trimmed for the same
    /// token-budget reason as personalityRule above — this addition alone
    /// (plus dataNotJudgmentRule, patterns[].suggested_approach,
    /// communication_style, and the [specific]/[general] tagging on
    /// compactLogs/compactParentContext) meaningfully lengthens the
    /// on-device prompt versus what shipped before 2026-08-25. Not yet
    /// verified against FoundationModels' 4096-token window the way the
    /// quoteRule removal was (that was an empirical finding, this isn't) —
    /// worth a real on-device smoke test before trusting this length.
    private static let autonomySupportiveRule = """
    For "suggested_approach" and "communication_style": ground advice in Self-Determination Theory — acknowledge the child's feeling BEFORE the parent's own view, don't jump straight to one-way advice. If the parent's own words are a direct command that overrides the child's autonomy (e.g. "you have to...", "just do it, no arguing"), set detected_pattern = "bald_on_record", quote it (or a close paraphrase) in example_before, and write a non-controlling rewrite in example_after — one that offers the child a choice. If there's no clear sign in the data, set detected_pattern = "unclear" — don't invent an example that isn't really there, and leave example_before/example_after null.
    """

    /// Kept in sync with PromptBuilder.swift's dataNotJudgmentRule /
    /// prompts.ts's DATA_NOT_JUDGMENT_RULE_ID.
    private static let dataNotJudgmentRule = """
    Present each "observation" as a PATTERN FROM THE DATA, not a verdict on the parent. Not "you push too hard about chores", but "a recorded pattern: chores conversations on Thursdays tend to be followed by a mood dip". Name specific days/topics when the data shows them clearly. Don't invent a pattern the data doesn't actually support.
    """

    static func extractionPrompt(for log: EmotionLog) -> String {
        """
        You help process a daily emotion log entry written by a child/teenager.

        The child wrote the following (if any free text):
        "\(log.journal ?? "(no text, quick-pick only)")"

        Additional info from the quick pick: labels=[\(log.healthkit.labels.joined(separator: ","))], context=[\(log.healthkit.associations.joined(separator: ","))]

        Task 1 — Context extraction:
        For each of the 6 aspects below, determine whether it is ALREADY present in the child's text (quote/summarize from their own words) or NOT PRESENT at all:
        - FEELING: the child's current feeling
        - TRIGGER: what triggered that feeling
        - PERCEIVED_CAUSE: what the child thinks the cause/problem is
        - PRIOR_EFFORT: what the child has already tried to cope with it
        - FUTURE_PLAN: the child's plan going forward to address/prevent it
        - EXPECTED_OUTCOME: what the child hopes the outcome of that plan will be

        Do not invent an answer — if it's not in the child's text, mark null. Do not infer beyond what's written.

        Task 2 — Crisis signal:
        Mark true ONLY if the child's text shows a serious indication of self-harm, suicidal intent, or immediate danger to the child's safety. Do not mark true for ordinary negative emotions (sad, stressed, angry) — only for a clear crisis signal.

        Output MUST be valid JSON, no markdown, exactly this shape:
        {
          "extracted": {
            "FEELING": "<content or null>",
            "TRIGGER": "<content or null>",
            "PERCEIVED_CAUSE": "<content or null>",
            "PRIOR_EFFORT": "<content or null>",
            "FUTURE_PLAN": "<content or null>",
            "EXPECTED_OUTCOME": "<content or null>"
          },
          "crisis_signal": true or false
        }
        """
    }

    static func howToReactPrompt(for log: EmotionLog, childName: String) -> String {
        """
        You are an assistant that helps parents understand and respond to their child's emotion log with empathy.

        The child (name: \(childName)) just logged:
        \(compactLog(log))

        Write ONE short tip (max 2 sentences, plain text, no markdown) for the parent on how to respond to this moment. \(cautiousLanguageRule) \(personalityRule(childName: childName))

        Focus on tone and approach (e.g. listen first without judging, ask without pressuring), not technical solutions. Do not give specific medical or psychological advice.
        """
    }

    static func compactLogsTagged(_ entries: [PromptBuilder.TaggedEmotionLog]) -> String {
        entries.map { entry in
            let tag = entry.isSpecific ? "specific" : "general"
            let rest = compactLog(entry.log).dropFirst(2)
            return "- [\(tag)] \(rest)"
        }.joined(separator: "\n")
    }

    static func compactParentContextTagged(
        interactions: [PromptBuilder.TaggedParentInteraction],
        reflections: [PromptBuilder.TaggedParentReflection]
    ) -> String {
        var lines: [String] = []
        for t in interactions {
            let tag = t.isSpecific ? "specific" : "general"
            lines.append("- [\(tag)] \(String(t.interaction.timestamp.prefix(10))) [\(t.interaction.topic)] \"\(t.interaction.interaction)\" (parent feels: \(t.interaction.parentEmotion))")
        }
        if !reflections.isEmpty {
            lines.append("Parent reflection logs:")
            for t in reflections {
                let tag = t.isSpecific ? "specific" : "general"
                lines.append("- [\(tag)] \(String(t.reflection.timestamp.prefix(10))) feels \(t.reflection.emotion): \"\(t.reflection.note)\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func overviewPrompt(
        logs: [PromptBuilder.TaggedEmotionLog],
        interactions: [PromptBuilder.TaggedParentInteraction],
        reflections: [PromptBuilder.TaggedParentReflection],
        childName: String,
        childConfidenceTier: String,
        parentConfidenceTier: String
    ) -> String {
        let name = PromptBuilder.firstName(childName)
        let childSpecificCount = logs.filter(\.isSpecific).count
        let parentEntryCount = interactions.count + reflections.count
        let parentSpecificCount = interactions.filter(\.isSpecific).count + reflections.filter(\.isSpecific).count
        return """
        You are an empathetic family assistant. Combine the child's emotion log with the parent's context into a cautious, non-judgmental relationship overview, AND give a concrete, specific, low-effort communication adjustment for this week. The goal is to help the parent understand their child's perspective more empathetically, and move from one-way advice to validating the child's feeling first.

        This week's data:
        - Child: \(logs.count) entries, \(childSpecificCount) specific. Confidence: \(childConfidenceTier).
        - Parent: \(parentEntryCount) entries, \(parentSpecificCount) specific. Confidence: \(parentConfidenceTier).

        Child's emotion log (past week, tagged [specific] or [general] per entry):
        \(compactLogsTagged(logs))
        Parent's context (recent interactions and reflections, tagged [specific] or [general] per entry):
        \(compactParentContextTagged(interactions: interactions, reflections: reflections))

        Produce a structured summary as JSON only, exactly this shape:

        {
          "overview": {
            "headline": "<1 short sentence, max 10 words, cautious>",
            "summary": "<1-2 short sentences on overall patterns, cautious>",
            "patterns": [
              {
                "topic": "Education|Friends|Family|Other",
                "observation": "<1 short sentence, cautious, as specific as the data allows>",
                "suggested_approach": "<1 sentence: a concrete communication adjustment to try this week, starting with acknowledging the child's feeling>"
              }
            ],
            "relationship_signal": {
              "parent_concern": "low|moderate|high",
              "child_openness": "low|moderate|high",
              "possible_misalignment": true
            },
            "communication_style": {
              "detected_pattern": "bald_on_record|autonomy_supportive|unclear",
              "example_before": "<quote/close paraphrase from the parent's notes, or null>",
              "example_after": "<its non-controlling rewrite, or null>"
            },
            "data_confidence": {
              "child": "<use the confidence value given above as-is — DO NOT recompute it>",
              "parent": "<use the confidence value given above as-is — DO NOT recompute it>"
            },
            "key_insight": "<1 short sentence connecting the parent's and child's perspectives as a possibility, not a fact>"
          }
        }

        Rules:
        - Focus on patterns across multiple entries, not a single event.
        - Treat emotion logs as signals, not objective truth.
        - An entry tagged [general] is a WEAK signal, not an empty one. Don't base a "pattern" mainly on [general] entries — they can still be mentioned as context. Base pattern claims mainly on [specific] entries.
        - If data_confidence.child is "low" — usually because the child only logged 1-2 times this week, or most entries are [general] — do NOT claim a "pattern" on the child's side. Just describe what's there plainly (e.g. "only one entry this week, not enough to see a pattern yet"), and child_openness/possible_misalignment should reflect that limitation, not assume complete data.
        - \(cautiousLanguageRule)
        - \(autonomySupportiveRule)
        - \(dataNotJudgmentRule)
        - \(personalityRule(childName: name)) (applies to summary and key_insight)
        - Consider both the child's and the parent's perspective.
        - Output valid JSON only, no markdown, no extra commentary.
        """
    }

    /// Adapts DummyDataset (no isSpecific/confidence fields in the fixture)
    /// to overviewPrompt's tagged params — same placeholder-false caveat as
    /// PromptBuilder.swift's adapter of the same shape.
    static func overviewPrompt(_ data: DummyDataset) -> String {
        let taggedLogs = data.emotionLogs.map { PromptBuilder.TaggedEmotionLog(log: $0, isSpecific: false) }
        let taggedInteractions = data.parentContext.recentInteractions.map {
            PromptBuilder.TaggedParentInteraction(interaction: $0, isSpecific: false)
        }
        let taggedReflections = data.parentContext.parentLogs.map {
            PromptBuilder.TaggedParentReflection(reflection: $0, isSpecific: false)
        }
        return overviewPrompt(
            logs: taggedLogs,
            interactions: taggedInteractions,
            reflections: taggedReflections,
            childName: PromptBuilder.firstName(data.child.name),
            childConfidenceTier: PromptBuilder.deriveConfidenceTier(entryCount: taggedLogs.count, specificEntryCount: 0),
            parentConfidenceTier: PromptBuilder.deriveConfidenceTier(
                entryCount: taggedInteractions.count + taggedReflections.count,
                specificEntryCount: 0
            )
        )
    }

    /// English mirror of PromptBuilder.swift's parentOnlyOverviewPrompt —
    /// runs when there's no child data yet, so it must never assert the
    /// child's feelings/perspective as fact. Not wired into
    /// DummyDataset/BenchmarkTask, same as the Indonesian version (needs
    /// fixture data for parent guided-journal entries that doesn't exist).
    static func compactParentLogEntries(_ entries: [PromptBuilder.ParentLogEntryForPrompt]) -> String {
        entries.map { entry in
            let tag = entry.isSpecific ? "specific" : "general"
            let qa = entry.answers
                .map { "\($0.field.rawValue.lowercased()): \"\($0.questionText)\" -> \"\($0.answerText)\"" }
                .joined(separator: " | ")
            return "- [\(tag)] \(String(entry.timestamp.prefix(10))) \(qa)"
        }.joined(separator: "\n")
    }

    static func parentOnlyOverviewPrompt(
        entries: [PromptBuilder.ParentLogEntryForPrompt],
        childName: String,
        confidenceTier: String
    ) -> String {
        let name = PromptBuilder.firstName(childName)
        let specificCount = entries.filter(\.isSpecific).count
        return """
        You are an empathetic personal coach for parents. Your job is to analyze the parent's own reflection notes (this week) to help them build emotional vocabulary and more autonomy-supportive communication patterns — BEFORE they practice it with their child. You have NO data from the child at all at this stage, so never make a confident claim or guess about the child's feelings or perspective.

        This week's data: \(entries.count) parent entries, \(specificCount) of them specific (containing cause-and-effect/insight language). Confidence this week: \(confidenceTier).

        Parent's reflection notes (this week, tagged [specific] or [general] per entry):
        \(compactParentLogEntries(entries))

        Produce a structured summary as JSON only, exactly this shape:
        {
          "overview": {
            "headline": "<1 short sentence, max 10 words, cautious>",
            "summary": "<1-2 sentences about patterns in the PARENT'S OWN notes this week — not about the child's state>",
            "patterns": [
              {
                "topic": "Education|Friends|Family|Other",
                "observation": "<1 short sentence, cautious, about a pattern in how the parent tells or reacts to things — as specific as the data allows>",
                "suggested_approach": "<1 sentence: a concrete communication adjustment to try next week, starting with acknowledging the child's feeling>"
              }
            ],
            "parent_signal": {
              "frustration_level": "low|moderate|high",
              "reflection_depth": "surface|building|specific"
            },
            "communication_style": {
              "detected_pattern": "bald_on_record|autonomy_supportive|unclear",
              "example_before": "<quote/close paraphrase from the parent's notes, or null>",
              "example_after": "<its non-controlling rewrite, or null>"
            },
            "data_confidence": "<use the confidence value given above as-is — DO NOT recompute it>",
            "key_insight": "<1 short sentence about a pattern or assumption that might exist in how the parent sees this situation, framed as a possibility to reflect on — not a verdict, and not a claim about what the child actually feels>"
          }
        }

        Rules:
        - Focus on patterns across multiple entries, not a single event.
        - Treat the parent's notes as one side of the story, not objective truth about the child.
        - An entry tagged [general] is a WEAK signal, not an empty one. Don't base a "pattern" or key_insight mainly on [general] entries — they can still be mentioned as context. Base pattern claims mainly on [specific] entries.
        - If the given confidence is "low" (whether from few entries, or mostly [general] ones), do NOT claim a strong pattern. Just describe lightly what's there, and leave patterns empty or minimal if the data isn't enough yet.
        - NEVER describe the child's feelings, intentions, or perspective as fact — you only have the parent's story about the child, not the child's own story. If you need to mention a possible child perspective, use phrasing like "the child may feel..., though this isn't confirmed from the child's side."
        - \(cautiousLanguageRule)
        - \(autonomySupportiveRule)
        - \(dataNotJudgmentRule)
        - \(personalityRule(childName: name)) (applies to summary and key_insight)
        - Output valid JSON only, no markdown, no extra commentary.
        """
    }

    static func reflectionPrompt(_ data: DummyDataset) -> String {
        """
        You are an empathetic family assistant. Based on the child's full emotion log history and the parent's context, provide reflection recommendations to help the parent connect better with their child.

        Full emotion log history:
        \(compactLogs(data))

        Parent's context:
        \(compactParentContext(data))

        Produce 2-3 short reflection recommendations as JSON only, exactly this shape:

        {
          "recommendations": [
            {
              "title": "<short, neutral title>",
              "description": "<1 short sentence of reflection/conversation suggestion for the parent, cautious>",
              "based_on": "<1 short phrase on what pattern in the data this is based on>"
            }
          ]
        }

        Rules:
        - Recommendations should be invitations to reflect/talk, not medical or psychological instructions.
        - Base them on recurring patterns, not a single event.
        - \(cautiousLanguageRule)
        - \(personalityRule(childName: PromptBuilder.firstName(data.child.name))) (applies to description)
        - Output valid JSON only, no markdown, no extra commentary.
        """
    }

    static func prompt(for task: BenchmarkTask, data: DummyDataset) -> String {
        switch task {
        case .extraction: return extractionPrompt(for: PromptBuilder.representativeLog(data))
        case .howToReact: return howToReactPrompt(for: PromptBuilder.representativeLog(data), childName: PromptBuilder.firstName(data.child.name))
        case .overview: return overviewPrompt(data)
        case .reflection: return reflectionPrompt(data)
        }
    }
}
