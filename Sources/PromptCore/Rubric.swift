import Foundation

/// The quality model the whole app runs on: a fixed, weighted rubric plus a defect taxonomy.
///
/// Every stage — diagnose, write, verify, repair — speaks these axis ids, so a score from the
/// analyzer is directly comparable with a score from the critic, and a repair pass can be judged
/// against the same bar it was asked to clear. The axis text is injected into the meta-prompts
/// verbatim, which keeps the prompt and the UI from drifting apart.
public enum Axis: String, CaseIterable, Codable, Identifiable {
    case goal, context, inputs, deliverable, criteria, constraints
    case procedure, autonomy, verification, consistency, economy, robustness

    public var id: String { rawValue }

    /// Resolve a model-supplied axis name to an axis.
    ///
    /// Models return "output contract" for `deliverable` and "success criteria" for `criteria`.
    /// Before this, an unrecognised key silently scored that axis at the generic 2 with no trace,
    /// so a misnamed axis cost 3-4 points on the 0-100 and nobody could see why.
    public static func match(_ raw: String) -> Axis? {
        let key = raw.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if let exact = Axis(rawValue: key) { return exact }
        let aliases: [String: Axis] = [
            "output_contract": .deliverable, "output_format": .deliverable, "format": .deliverable,
            "success_criteria": .criteria, "acceptance_criteria": .criteria, "criteria": .criteria,
            "instruction": .goal, "objective": .goal, "purpose": .goal, "intent": .goal,
            "background": .context, "situation": .context,
            "input": .inputs, "materials": .inputs, "resources": .inputs,
            "scope": .constraints, "boundaries": .constraints, "limits": .constraints,
            "steps": .procedure, "process": .procedure, "approach": .procedure,
            "escalation": .autonomy, "confirmation": .autonomy,
            "verification": .verification, "testing": .verification, "checks": .verification,
            "contradiction": .consistency, "internal_consistency": .consistency,
            "concision": .economy, "brevity": .economy, "length": .economy,
            "edge_cases": .robustness, "failure_handling": .robustness, "errors": .robustness,
        ]
        return aliases[key]
    }

    public var title: String {
        switch self {
        case .goal: return "Goal & intent"
        case .context: return "Context"
        case .inputs: return "Inputs & resources"
        case .deliverable: return "Output contract"
        case .criteria: return "Success criteria"
        case .constraints: return "Scope & constraints"
        case .procedure: return "Approach"
        case .autonomy: return "Autonomy & escalation"
        case .verification: return "Verification"
        case .consistency: return "Internal consistency"
        case .economy: return "Economy"
        case .robustness: return "Failure handling"
        }
    }

    /// The single question the axis asks of a prompt.
    public var question: String {
        switch self {
        case .goal:
            return "Does it state the outcome wanted and why it matters, in terms of the user's problem?"
        case .context:
            return "Does it supply only the context the model cannot infer (audience, background, prior decisions, definitions), and leave out what the model already knows?"
        case .inputs:
            return "Does it name the material that exists (files, data, links, examples), say where it is, and say what the model must fetch itself?"
        case .deliverable:
            return "Is the output contract exact — format, structure, length, language, tone — including what the output must not contain?"
        case .criteria:
            return "Are the success criteria observable and falsifiable: a command to run, a field to read, a number to hit, a check another person could repeat?"
        case .constraints:
            return "Is scope bounded — what is in, what is explicitly out, what is prohibited, and what budget (time, length, cost) applies?"
        case .procedure:
            return "For multi-step work, is there a decomposition with an order of operations and stopping conditions, without micromanaging every step?"
        case .autonomy:
            return "Does it say what the executor may decide alone, and which actions need confirmation first (destructive, irreversible, shared, outward-facing, costly)?"
        case .verification:
            return "Does it say how the result must be checked before it is called done, and what evidence to show for that check?"
        case .consistency:
            return "Is the prompt free of contradictions, duplicated rules and undefined terms? Conflicting instructions cost more than vague ones on current models."
        case .economy:
            return "Is every line load-bearing — no persona theatre, no restated obviousness, no rule list that should be one principle with a reason?"
        case .robustness:
            return "Does it define behaviour for missing data, ambiguous requests, partial failure and out-of-scope input?"
        }
    }

    /// 4 = specific and checkable, 2 = present but generic, 0 = absent. Anchors keep scoring honest.
    public var anchor4: String {
        switch self {
        case .goal:
            return "One or two sentences naming the outcome, who benefits and why it matters. A competent stranger can tell whether the work is on-target."
        case .context:
            return "Each fact is one the model could not know, and each one changes a decision. Audience, prior decisions and non-obvious definitions are present where they exist; general knowledge is not restated, and an axis with nothing to add says so rather than padding."
        case .inputs:
            return "Every input is named with its location or shape, and the prompt separates what is supplied from what must be retrieved — or the prompt states that none exists and forbids inventing one."
        case .deliverable:
            return "Format, structure, length with a number, language and tone are pinned where they matter, plus at least one explicit exclusion (what not to include). A short task may pin fewer of these; what is pinned is not left to chance."
        case .criteria:
            return "Every criterion is checkable by someone who did not do the work: a command, a field, a threshold, a repeatable comparison."
        case .constraints:
            return "In-scope and out-of-scope are both explicit, prohibitions come with the reason, and any budget is a number."
        case .procedure:
            return "Phases with an order, a stopping condition per phase, and freedom inside each phase. A one-step task needs no phases at all, and is not penalised for having none."
        case .autonomy:
            return "Default is act; a short list of action classes requires confirmation, each with the reason. Obstacles never justify destructive shortcuts."
        case .verification:
            return "Each success criterion has a named check, the evidence to report (command output, field value, source), and what to do when a check fails. Missing criteria are charged to `criteria` alone; score verification on whether the checks that do exist are real."
        case .consistency:
            return "No rule pair conflicts and no term is used two ways. Where two goals genuinely pull apart, an explicit priority order settles it; where they do not, the prompt does not invent one."
        case .economy:
            return "Reads as instructions from a senior engineer: dense, reasoned, no filler. Removing any line would lose information."
        case .robustness:
            return "Every failure class this medium can actually have gets a stated response, including when to stop and ask: for an agent run that is missing data, ambiguity, partial failure and out-of-scope requests; for a chat turn it is missing data and ambiguity."
        }
    }

    public var anchor2: String {
        switch self {
        case .goal:
            return "An objective is stated but generic, so trade-offs are unguided and two readers would build different things."
        case .context:
            return "Some background is given, but it mixes inferable generalities with the few facts that actually matter."
        case .inputs:
            return "Inputs are mentioned in passing without location, shape or ownership."
        case .deliverable:
            return "A format is implied by the task type but not pinned; length and language are left to chance."
        case .criteria:
            return "Criteria are adjectives ('high quality', 'thorough') that nobody could fail."
        case .constraints:
            return "Scope is implied by the task but the boundary cases and budget are unstated."
        case .procedure:
            return "Steps are listed flat, with no order, no stopping conditions and no room to deviate."
        case .autonomy:
            return "Autonomy is mentioned ('ask if unsure') without naming the actions that actually need a pause."
        case .verification:
            return "'Check your work' with no definition of the check or the evidence."
        case .consistency:
            return "No outright contradiction, but a rule is duplicated with slightly different wording, or a term is undefined."
        case .economy:
            return "Mostly useful, with a paragraph of restatement or a rule list that could be compressed."
        case .robustness:
            return "Failure handling is reduced to 'handle errors gracefully'."
        }
    }

    public var anchor0: String {
        switch self {
        case .goal: return "No objective; only a topic, a verb or a vibe."
        case .context: return "Nothing but the bare request."
        case .inputs: return "No mention of what material exists, and no statement that there is none. A prompt that says it has no inputs and forbids inventing them is not a 0."
        case .deliverable: return "No statement about the output at all."
        case .criteria: return "Nothing that could distinguish a good result from a bad one."
        case .constraints: return "Nothing is out of scope, so everything is."
        case .procedure: return "No approach; the model is left to invent one."
        case .autonomy: return "No guidance, so the executor guesses when to stop."
        case .verification: return "Nothing about checking the result."
        case .consistency: return "Two rules directly contradict, or a term means two things."
        case .economy: return "Padding, persona theatre, or shouting replaces instruction."
        case .robustness: return "Any gap in the input stops the work."
        }
    }

    /// Weight of the axis in the 0–100 score. Autonomy and verification matter far more for an
    /// agent that touches a filesystem than for a one-shot chat message.
    public func weight(for target: PromptTarget) -> Int {
        switch (self, target) {
        case (.autonomy, .chat): return 0
        // A system prompt that runs unattended needs act-vs-ask settled more than a chat message
        // does; a chat message needs it not at all.
        case (.autonomy, .systemPrompt): return 2
        // An unattended agent that touches a filesystem or a shared system needs act-vs-ask
        // settled more than it needs a tidy output contract, so this outweighs the default 3.
        case (.autonomy, .agentTask): return 4
        case (.verification, .chat): return 1
        case (.verification, .agentTask): return 3
        // A system prompt is a standing brief, so its procedure matters less than an agent's.
        case (.procedure, .systemPrompt): return 1
        case (.procedure, .chat): return 1
        case (.procedure, .agentTask): return 3
        case (.goal, _): return 3
        case (.deliverable, _): return 3
        case (.criteria, _): return 3
        // Contradictions are named the worst defect in four separate instructions, and D07 is a
        // blocker. Weighted below autonomy, the arithmetic contradicted the prose.
        case (.consistency, .agentTask): return 4
        case (.consistency, _): return 3
        case (.context, _): return 2
        case (.inputs, _): return 2
        case (.constraints, _): return 2
        case (.economy, _): return 2
        case (.robustness, _): return 2
        default: return 2
        }
    }

    public static func applicable(to target: PromptTarget) -> [Axis] {
        allCases.filter { $0.weight(for: target) > 0 }
    }
}

/// How much of a rubric score is the prompt and how much is the instrument.
///
/// The score is a weighted mean of twelve judgements a model makes in one pass. That is a useful
/// relative signal inside a single run and a useless absolute one across runs, and the difference
/// is large enough to be measured rather than assumed: four runs on one target with one draft and
/// one model returned 90, 80, 84 and 73. Seventeen points, same text, same critic.
///
/// So the panel shows the number without inviting a comparison, and every place that *does*
/// compare two scores — the harness's repair trace, a before/after in a report — goes through
/// `delta`, which refuses to name a winner inside the spread. A tool that says "73, was 88" leaves
/// the reader to conclude the prompt got worse; the honest reading is that the critic moved.
public enum RubricNoise {

    /// Widest difference observed between two runs on identical text, in rubric points. Any two
    /// scores closer together than this are indistinguishable, so a comparison inside the band is
    /// reported as unchanged rather than as a small win or a small regression.
    public static let measuredSpread = 17

    public enum Delta: Equatable {
        case better(Int)
        case worse(Int)
        /// The gap is not larger than the spread. Not a tie — an unanswerable comparison.
        case withinNoise

        /// Short clause for a log line or a panel row.
        public var note: String {
            switch self {
            case .withinNoise: return "inside the \(RubricNoise.measuredSpread)-point run-to-run spread"
            case .better(let n): return "up \(n), beyond the spread"
            case .worse(let n): return "down \(abs(n)), beyond the spread"
            }
        }
    }

    /// Compares two scores of the same prompt, or two runs of the same critic.
    ///
    /// `<=` and not `<`: the measured 17-point gap was observed between two real runs, so a 17-point
    /// difference is exactly the case that must not be called a change.
    public static func delta(from before: Int, to after: Int) -> Delta {
        let change = after - before
        if abs(change) <= measuredSpread { return .withinNoise }
        return change > 0 ? .better(change) : .worse(change)
    }
}

/// A defect is a named failure mode, not an opinion. Codes are stable so the UI, the tests and the
/// meta-prompts can refer to them without repeating prose.
public struct Defect: Identifiable, Hashable {
    public let code: String
    public let title: String
    public let severity: Severity

    public enum Severity: String, Codable, CaseIterable { case blocker, major, minor }

    public var id: String { code }

    /// Ordered worst-first: this is also the order the analyzer is told to report in.
    /// Ordered worst-first, and the analyzer is told to report in this order. The list is the
    /// severity order, so anything reading it top-down sees blockers before majors before minors.
    public static let all: [Defect] = [
        // D17, D18, D19 and D20 exist because live runs shipped defects the taxonomy could not
        // name: an invented specific, a criterion nobody could check, padding to reach a length
        // target, and ritual that adds tokens without adding information.
        .init(code: "D01", title: "No objective: the request names an activity, not an outcome", severity: .blocker),
        .init(code: "D02", title: "No success criteria: nothing could fail", severity: .blocker),
        .init(code: "D03", title: "No output contract: format, length or language left to chance", severity: .blocker),
        .init(code: "D07", title: "Contradiction: two rules that cannot both be followed", severity: .blocker),
        .init(code: "D16", title: "Does the task instead of instructing how to do it", severity: .blocker),
        .init(code: "D17", title: "Asserts a specific the request did not supply (price, name, URL, count)", severity: .blocker),
        .init(code: "D04", title: "Missing context the model cannot infer, including who reads it", severity: .major),
        .init(code: "D05", title: "Inputs unnamed: no location, shape or owner", severity: .major),
        .init(code: "D06", title: "Unbounded scope: nothing is out of scope", severity: .major),
        .init(code: "D08", title: "Unstated assumption that changes the result", severity: .major),
        .init(code: "D11", title: "No failure policy for missing data or ambiguity", severity: .major),
        .init(code: "D12", title: "No verification: 'check your work' with no check", severity: .major),
        .init(code: "D15", title: "Unsafe autonomy: destructive or outward-facing actions unguarded", severity: .major),
        .init(code: "D18", title: "Criterion the executor cannot check with the tools it has", severity: .major),
        .init(code: "D09", title: "Vague quantifier: 'some', 'appropriate', 'as needed'", severity: .minor),
        .init(code: "D10", title: "Unbounded effort: 'thorough', 'comprehensive', 'as much as possible'", severity: .minor),
        .init(code: "D13", title: "Filler: persona theatre, shouting, threats, restated obviousness", severity: .minor),
        .init(code: "D19", title: "Padding: lines that exist to reach a length target rather than to inform", severity: .minor),
        .init(code: "D20", title: "Ritual instruction: 'think step by step' and similar, which changes nothing", severity: .minor),
    ]

    public static func severity(for code: String) -> Severity {
        all.first { $0.code == code }?.severity ?? .minor
    }
}

/// One thing the analyzer found, with the quote that proves it and the fix that closes it.
