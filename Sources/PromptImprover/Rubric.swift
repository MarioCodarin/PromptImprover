import Foundation

/// The quality model the whole app runs on: a fixed, weighted rubric plus a defect taxonomy.
///
/// Every stage — diagnose, write, verify, repair — speaks these axis ids, so a score from the
/// analyzer is directly comparable with a score from the critic, and a repair pass can be judged
/// against the same bar it was asked to clear. The axis text is injected into the meta-prompts
/// verbatim, which keeps the prompt and the UI from drifting apart.
enum Axis: String, CaseIterable, Codable, Identifiable {
    case goal, context, inputs, deliverable, criteria, constraints
    case procedure, autonomy, verification, consistency, economy, robustness

    var id: String { rawValue }

    var title: String {
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
    var question: String {
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
    var anchor4: String {
        switch self {
        case .goal:
            return "One or two sentences naming the outcome, who benefits and why it matters. A competent stranger can tell whether the work is on-target."
        case .context:
            return "Each fact is one the model could not know, and each one changes a decision. Audience, prior decisions and non-obvious definitions are present; general knowledge is not restated."
        case .inputs:
            return "Every input is named with its location or shape, and the prompt separates what is supplied from what must be retrieved."
        case .deliverable:
            return "Format, structure, length, language and tone are pinned, plus at least one explicit exclusion (what not to include)."
        case .criteria:
            return "Every criterion is checkable by someone who did not do the work: a command, a field, a threshold, a repeatable comparison."
        case .constraints:
            return "In-scope and out-of-scope are both explicit, prohibitions come with the reason, and any budget is a number."
        case .procedure:
            return "Phases with an order, a stopping condition per phase, and freedom inside each phase. Says when to skip a phase."
        case .autonomy:
            return "Default is act; a short list of action classes requires confirmation, each with the reason. Obstacles never justify destructive shortcuts."
        case .verification:
            return "A named check per success criterion, the evidence to report (command output, field value, source), and what to do when a check fails."
        case .consistency:
            return "No rule pair conflicts, no term is used two ways, and any tension between speed and thoroughness is resolved by an explicit priority order."
        case .economy:
            return "Reads as instructions from a senior engineer: dense, reasoned, no filler. Removing any line would lose information."
        case .robustness:
            return "Missing data, ambiguity, partial failure and out-of-scope requests each have a stated response, including when to stop and ask."
        }
    }

    var anchor2: String {
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

    var anchor0: String {
        switch self {
        case .goal: return "No objective; only a topic, a verb or a vibe."
        case .context: return "Nothing but the bare request."
        case .inputs: return "No mention of what material exists."
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
    func weight(for target: PromptTarget) -> Int {
        switch (self, target) {
        case (.autonomy, .chat): return 0
        case (.autonomy, .systemPrompt): return 1
        // An unattended agent that touches a filesystem or a shared system needs act-vs-ask
        // settled more than it needs a tidy output contract.
        case (.autonomy, .agentTask): return 3
        case (.verification, .chat): return 1
        case (.verification, .agentTask): return 3
        case (.procedure, .chat): return 1
        case (.goal, _): return 3
        case (.deliverable, _): return 3
        case (.criteria, _): return 3
        case (.consistency, _): return 3
        case (.context, _): return 2
        case (.inputs, _): return 2
        case (.constraints, _): return 2
        case (.economy, _): return 2
        case (.robustness, _): return 2
        default: return 2
        }
    }

    static func applicable(to target: PromptTarget) -> [Axis] {
        allCases.filter { $0.weight(for: target) > 0 }
    }
}

/// A defect is a named failure mode, not an opinion. Codes are stable so the UI, the tests and the
/// meta-prompts can refer to them without repeating prose.
struct Defect: Identifiable, Hashable {
    let code: String
    let title: String
    let severity: Severity

    enum Severity: String, Codable, CaseIterable { case blocker, major, minor }

    var id: String { code }

    /// Ordered worst-first: this is also the order the analyzer is told to report in.
    static let all: [Defect] = [
        // D17 and D18 exist because both live runs shipped defects the taxonomy could not name:
        // invented specifics, and criteria the executor has no way to check.
        .init(code: "D17", title: "Asserts a specific the request did not supply (price, name, URL, count)", severity: .blocker),
        .init(code: "D18", title: "Criterion the executor cannot check with the tools it has", severity: .major),
        .init(code: "D01", title: "No objective: the request names an activity, not an outcome", severity: .blocker),
        .init(code: "D02", title: "No success criteria: nothing could fail", severity: .blocker),
        .init(code: "D03", title: "No output contract: format, length or language left to chance", severity: .blocker),
        .init(code: "D07", title: "Contradiction: two rules that cannot both be followed", severity: .blocker),
        .init(code: "D16", title: "Does the task instead of instructing how to do it", severity: .blocker),
        .init(code: "D04", title: "Missing context the model cannot infer", severity: .major),
        .init(code: "D05", title: "Inputs unnamed: no location, shape or owner", severity: .major),
        .init(code: "D06", title: "Unbounded scope: nothing is out of scope", severity: .major),
        .init(code: "D08", title: "Unstated assumption that changes the result", severity: .major),
        .init(code: "D11", title: "No failure policy for missing data or ambiguity", severity: .major),
        .init(code: "D12", title: "No verification: 'check your work' with no check", severity: .major),
        .init(code: "D15", title: "Unsafe autonomy: destructive or outward-facing actions unguarded", severity: .major),
        .init(code: "D09", title: "Vague quantifier: 'some', 'appropriate', 'as needed'", severity: .minor),
        .init(code: "D10", title: "Unbounded effort: 'thorough', 'comprehensive', 'as much as possible'", severity: .minor),
        .init(code: "D13", title: "Filler: persona theatre, shouting, threats, restated obviousness", severity: .minor),
        .init(code: "D14", title: "Unstated audience", severity: .minor),
    ]

    static func severity(for code: String) -> Severity {
        all.first { $0.code == code }?.severity ?? .minor
    }
}

/// One thing the analyzer found, with the quote that proves it and the fix that closes it.
struct Finding: Identifiable, Hashable {
    var code: String
    var severity: Defect.Severity
    var quote: String
    var fix: String

    var id: String { code + quote }

    var title: String { Defect.all.first { $0.code == code }?.title ?? "Defect \(code)" }
}

/// Per-axis verdict. `note` is the justification; it comes before the number in the JSON on purpose.
struct AxisVerdict: Codable, Hashable {
    var score: Int
    var note: String
}

struct Diagnosis {
    var brief = ""
    var taskType = ""
    var domain = ""
    var risk = "low"
    var findings: [Finding] = []
    var scores: [String: AxisVerdict] = [:]
    var assumptions: [String] = []
    var questions: [ClarifyingQuestion] = []

    /// Weighted 0–100. Missing axes score 2 (the "generic" anchor) and say so in the note.
    func total(for target: PromptTarget) -> Int {
        let axes = Axis.applicable(to: target)
        let weight = axes.reduce(0) { $0 + $1.weight(for: target) }
        guard weight > 0 else { return 0 }
        let sum = axes.reduce(0.0) { acc, axis in
            let raw = scores[axis.rawValue]?.score ?? 2
            return acc + Double(max(0, min(4, raw))) * Double(axis.weight(for: target))
        }
        return Int((sum / (Double(weight) * 4.0) * 100).rounded())
    }

    var blockers: [Finding] { findings.filter { $0.severity == .blocker } }
}

/// One problem the critic found in a written prompt. Distinct from `Finding` because the critic
/// judges a prompt that already exists and must quote it exactly.
struct CritiqueIssue: Identifiable, Hashable {
    var axis: String
    var severity: Defect.Severity
    var quote: String
    var problem: String
    var fix: String

    var id: String { axis + quote + problem }
}

struct Critique {
    var verdict = "ship"          // "ship" | "repair"
    var summary = ""
    var scores: [String: AxisVerdict] = [:]
    var issues: [CritiqueIssue] = []
    var strengths: [String] = []

    var needsRepair: Bool {
        verdict == "repair" || issues.contains { $0.severity != .minor }
    }

    func total(for target: PromptTarget) -> Int {
        Diagnosis(scores: scores).total(for: target)
    }
}

/// A single acceptance test for the generated prompt: something the user can paste in to check
/// whether the prompt actually works, before shipping it.
struct EvalCase: Identifiable, Hashable {
    var name: String
    var input: String
    var expects: [String]
    var trap: String

    var id: String { name + input }
}

struct EvalSuite {
    var cases: [EvalCase] = []
    var judgeRubric = ""

    var markdown: String {
        guard !cases.isEmpty else { return judgeRubric }
        var out = ["## Acceptance tests", ""]
        out.append("Run each input through the prompt. A pass means every expectation holds.")
        out.append("")
        for (i, c) in cases.enumerated() {
            out.append("### \(i + 1). \(c.name)")
            out.append("")
            out.append("**Input**")
            out.append("")
            out.append("```text")
            out.append(c.input)
            out.append("```")
            out.append("")
            out.append("**Passes when**")
            for e in c.expects { out.append("- \(e)") }
            if !c.trap.isEmpty {
                out.append("")
                out.append("*Why a weak prompt fails this:* \(c.trap)")
            }
            out.append("")
        }
        if !judgeRubric.isEmpty {
            out.append("## Judging")
            out.append("")
            out.append(judgeRubric)
        }
        return out.joined(separator: "\n")
    }
}

/// How many model calls the pipeline is allowed to spend, and what it does with them.
enum Rigor: String, CaseIterable, Identifiable, Codable {
    case fast = "Fast"
    case standard = "Standard"
    case deep = "Deep"

    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .fast: return "Write only. One call. For throwaway prompts."
        case .standard: return "Diagnose, write, verify against the rubric, repair real defects. Three to four calls."
        case .deep: return "Standard plus a second verification pass and an acceptance-test suite. Five to six calls."
        }
    }

    /// Stage names for the progress row, so the panel says what is happening rather than "working".
    var stages: [String] {
        switch self {
        case .fast: return ["Write", "Lint"]
        case .standard: return ["Diagnose", "Write", "Lint", "Verify", "Repair"]
        case .deep: return ["Diagnose", "Write", "Lint", "Verify", "Repair", "Tests"]
        }
    }

    var verifies: Bool { self != .fast }
    var repairs: Bool { self != .fast }
    var writesTests: Bool { self == .deep }
}
