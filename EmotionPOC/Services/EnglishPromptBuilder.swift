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

    /// Kept in sync with PromptBuilder.swift's personalityRule. Written in
    /// English here since this whole field gets translated back to
    /// Indonesian afterward (OnDeviceTranslationPipeline.swift) — the
    /// child's name should pass through untouched as a proper noun, but
    /// that's an assumption, not verified against the on-device Translator.
    private static func personalityRule(childName: String) -> String {
        """
        You are a wise family companion — a woman in her 50s, with years of experience supporting many families. Your delivery is assertive and confident (not wishy-washy or hedgy), but still warm — like a trusted friend who's known the family a long time, not a clinical report. Validate the PARENT's own difficulty too (e.g. "I know moments like this with \(childName) aren't always easy, but from experience, try..."), use \(childName)'s name naturally. The assertiveness is in HOW you deliver advice, NOT in claims about the child's feelings — those still follow the cautious-language rule below.
        """
    }

    /// Kept in sync with PromptBuilder.swift's quoteRule — same reasoning:
    /// HumanReadable.swift's QuoteAwareText splits on quoted spans.
    private static let quoteRule = """
    Do NOT wrap your entire answer in quotes. Double quotes ("...") are ONLY for one specific sentence you suggest the parent say to the child, if any — everything else (explanation/context) stays unquoted outside that sentence.
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

        Write ONE short tip (max 2 sentences, plain text, no markdown) for the parent on how to respond to this moment. \(cautiousLanguageRule) \(personalityRule(childName: childName)) \(quoteRule)

        Focus on tone and approach (e.g. listen first without judging, ask without pressuring), not technical solutions. Do not give specific medical or psychological advice.
        """
    }

    static func overviewPrompt(_ data: DummyDataset) -> String {
        """
        You are an empathetic family assistant. Your task is to combine the child's emotion log with the parent's context into a cautious, non-judgmental relationship overview. The goal is to help the parent understand their child's perspective more empathetically.

        Child's emotion log (past week):
        \(compactLogs(data))

        Parent's context (recent interactions and reflections):
        \(compactParentContext(data))

        Produce a structured summary as JSON only, exactly this shape:

        {
          "overview": {
            "headline": "<1 sentence, cautious>",
            "summary": "<2-3 sentences on overall patterns, cautious>",
            "patterns": [
              { "topic": "Education|Friends|Family|Other", "observation": "<1 sentence, cautious>" }
            ],
            "relationship_signal": {
              "parent_concern": "low|moderate|high",
              "child_openness": "low|moderate|high",
              "possible_misalignment": true
            },
            "key_insight": "<1 sentence connecting the parent's and child's perspectives as a possibility, not a fact>"
          }
        }

        Rules:
        - Focus on patterns across multiple entries, not a single event.
        - Treat emotion logs as signals, not objective truth.
        - \(cautiousLanguageRule)
        - \(personalityRule(childName: PromptBuilder.firstName(data.child.name))) (applies to summary and key_insight)
        - \(quoteRule)
        - Consider both the child's and the parent's perspective.
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

        Produce 2-4 reflection recommendations as JSON only, exactly this shape:

        {
          "recommendations": [
            {
              "title": "<short, neutral title>",
              "description": "<2-3 sentences of reflection/conversation suggestion for the parent, cautious>",
              "based_on": "<1 sentence on what pattern in the data this is based on>"
            }
          ]
        }

        Rules:
        - Recommendations should be invitations to reflect/talk, not medical or psychological instructions.
        - Base them on recurring patterns, not a single event.
        - \(cautiousLanguageRule)
        - \(personalityRule(childName: PromptBuilder.firstName(data.child.name))) (applies to description)
        - \(quoteRule)
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
