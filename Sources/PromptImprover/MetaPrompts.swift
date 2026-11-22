import Foundation

enum PromptTarget: String, CaseIterable, Identifiable {
    case agentTask = "Agent task"
    case systemPrompt = "System prompt"
    case chat = "Chat message"
    var id: String { rawValue }

    var guidance: String {
        switch self {
        case .agentTask:
            return """
            TARGET: an autonomous agent running in a harness with tools (e.g. Claude Code, Codex, OpenCode, \
            a custom agent loop). Address the agent in second person. In addition to the core sections, cover:
            - Autonomy: what it may decide on its own, and the few situations where it must stop and ask \
            (irreversible, destructive, costly or outward-facing actions; genuinely ambiguous goals).
            - Persistence: keep working until the success criteria are met; don't stop at a plan unless a plan is the deliverable.
            - Uncertainty: when a detail is missing, make the most reasonable assumption, note it, and continue.
            - Tools & sources, only where relevant (e.g. search the web and cite sources, prefer primary sources).
            - Verification: check the result against the success criteria before finishing.
            - Final report: what was done, how it was verified, open issues, assumptions made.
            """
        case .systemPrompt:
            return """
            TARGET: a reusable system prompt that governs many future conversations. Describe the assistant's \
            purpose, audience, core behaviors, priorities when instructions conflict, tone, default formatting, \
            and how to handle ambiguous or out-of-scope requests. Do not tailor it to one single request.
            """
        case .chat:
            return """
            TARGET: a single message pasted into a chat assistant. Keep it compact: goal, essential context, \
            constraints, deliverable, success criteria. Skip agent-only sections (autonomy, reporting).
            """
        }
    }
}

enum MetaPrompts {

    // MARK: Stage 1 — diagnose & decide what to ask

    static let analyzer = """
    You are the diagnostic stage of a prompt-improvement tool. The user gives you a rough request they plan \
    to hand to an AI model. You do not carry out the request and you do not write the improved prompt yet. \
    Your only job is to work out what is missing.

    Assess the draft on these dimensions:
    - Goal: the outcome wanted, and why it matters.
    - Done criteria: how anyone would know the result is good enough.
    - Audience & context: who the output is for, and background the model cannot infer.
    - Inputs: material, data or examples that exist, or that the model must find.
    - Constraints: scope, length, tone, sources, things to avoid, deadlines.
    - Deliverable: the exact form of the output.
    - Autonomy: what the model may decide alone vs. when it should stop and ask.

    Choose clarifying questions by these rules:
    - Ask only when the answer would materially change the prompt AND no sensible default exists. \
    If a reasonable default exists, don't ask. The writer will state it as an assumption.
    - Ask at most 4 questions, most important first. Zero questions is the right answer when the draft is clear enough.
    - Never ask about something the draft already states.
    - Keep each question short, concrete and answerable in a few words. Offer 2–4 likely options when the answers are predictable.
    - Treat the request as a general task. Don't assume a codebase, repository or files unless the draft mentions them.
    - Write in the language of the draft.

    Reply with JSON only. No prose, no code fences:
    {"analysis": "<2–4 sentences: what the user wants and the draft's main weaknesses>",
     "questions": [{"question": "...", "why": "<short clause: what the answer changes>", "options": ["...", "..."]}]}
    """

    static func analyzerInput(_ draft: String, target: PromptTarget) -> String {
        "Intended use: \(target.rawValue)\n\n<draft>\n\(draft)\n</draft>"
    }

    // MARK: Stage 2 — write the prompt

    static func writer(target: PromptTarget) -> String {
        """
        You are an expert prompt engineer. You turn a rough request into a complete, well-structured prompt \
        that a capable AI model or autonomous agent can carry out correctly on the first try. \
        You write the prompt. You never perform the task yourself.

        Principles (from current Anthropic, OpenAI and Google guidance on prompting frontier models and agents):
        1. Start with the goal and the reason behind it. Models generalize better from a purpose than from bare rules.
        2. Define "done" as concrete, checkable success criteria.
        3. Give the context the model cannot infer: audience, background, prior decisions, definitions. \
        Leave out what it already knows. Every line must earn its place.
        4. Write at the right altitude: specific enough to steer, general enough to cover cases nobody foresaw. \
        Prefer principles with reasons over long, brittle rule lists.
        5. Say what to do, not only what to avoid. When a prohibition is necessary, give the reason and the alternative.
        6. Make scope explicit: what is in, what is out, and what the model may decide alone.
        7. Specify the deliverable exactly: format, structure, length, language, tone.
        8. For multi-step work, describe the approach as phases (understand → plan → execute → verify → report) \
        without micromanaging every step.
        9. Add a short example only when a format or style is hard to describe in words, and label it as illustrative.
        10. Never invent facts the user did not give (names, numbers, sources, URLs, credentials). When a detail \
        is missing, choose a sensible default and list it under "Assumptions", or insert a {{PLACEHOLDER}}.
        11. Keep every requirement the user stated, and write in the user's language.
        12. No padding: no empty "world-class expert" personas, no ALL-CAPS shouting, no threats or bribes. \
        Calm, direct language works best on current models.
        13. The task is general-purpose. Don't assume a codebase, repository or files unless the user mentions them.

        Structure: Markdown headings, with XML-style tags around any block of reference material or data. \
        Adapt the sections to the task and drop any that would be empty. A typical skeleton:

        # <Task title>
        ## Goal
        ## Context
        ## Requirements
        ## Constraints & scope
        ## Approach
        ## Deliverable
        ## Success criteria
        ## Assumptions   (only if you made any)

        \(target.guidance)

        Output only the final prompt, ready to paste. No preamble, no commentary, no code fence around the whole thing.
        """
    }

    /// Builds the single user message sent to the writer from the draft + the Q&A round.
    static func composeBrief(draft: String, analysis: String, questions: [ClarifyingQuestion]) -> String {
        var parts = ["<draft>\n\(draft)\n</draft>"]
        if !analysis.isEmpty { parts.append("<diagnosis>\n\(analysis)\n</diagnosis>") }

        let answered = questions.filter { !$0.answer.trimmingCharacters(in: .whitespaces).isEmpty }
        if !answered.isEmpty {
            let qa = answered.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
            parts.append("<clarifications>\n\(qa)\n</clarifications>")
        }

        // TODO(human): decide what the writer should do with questions the user left unanswered.

        parts.append("Write the improved prompt now.")
        return parts.joined(separator: "\n\n")
    }

    /// Appends the user's profile (if any) so both stages tailor to the person, not just the draft.
    static func personalize(_ system: String, profile: String?) -> String {
        guard let profile else { return system }
        return system + """


        About the user. Use it to tailor the prompt. It overrides generic defaults, never explicit \
        statements in the draft. Don't ask questions this profile already answers, and don't copy it verbatim into the prompt:
        \(profile)
        """
    }

    // MARK: Helpers

    /// Removes <think>…</think> blocks some reasoning models emit inline (including an unclosed one mid-stream).
    static func stripThinking(_ s: String) -> String {
        var out = s
        while let start = out.range(of: "<think>") {
            if let end = out.range(of: "</think>", range: start.upperBound..<out.endIndex) {
                out.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                out.removeSubrange(start.lowerBound..<out.endIndex)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a single code fence wrapping the whole output, if a model added one anyway.
    static func unfence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```"), t.hasSuffix("```"), t.count > 6 else { return t }
        var lines = t.components(separatedBy: "\n")
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tolerant JSON extraction: models sometimes wrap JSON in prose or fences.
    static func parseAnalysis(_ raw: String) -> (String, [ClarifyingQuestion]) {
        let text = stripThinking(raw)
        struct Payload: Decodable {
            struct Q: Decodable { let question: String; let why: String?; let options: [String]? }
            let analysis: String?
            let questions: [Q]?
        }
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"),
              let p = try? JSONDecoder().decode(Payload.self, from: Data(text[a...b].utf8))
        else { return (text, []) }
        let qs = (p.questions ?? []).prefix(4).map {
            ClarifyingQuestion(question: $0.question, why: $0.why ?? "", options: $0.options ?? [])
        }
        return (p.analysis ?? "", Array(qs))
    }
}

struct ClarifyingQuestion: Identifiable, Hashable {
    let id = UUID()
    var question: String
    var why: String
    var options: [String]
    var answer = ""
}
