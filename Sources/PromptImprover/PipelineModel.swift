import Foundation

/// The data that flows between stages: what the analyzer reports, what the critic
/// reports, what the eval suite contains, and how deep a run goes.

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
    var risk = "low"
    var findings: [Finding] = []
    var scores: [String: AxisVerdict] = [:]
    var assumptions: [String] = []
    var questions: [ClarifyingQuestion] = []

    /// Axes the model returned nothing for. They score the generic 2, so the caller can say which
    /// ones were assumed rather than judged.
    func missingAxes(for target: PromptTarget) -> [Axis] {
        Axis.applicable(to: target).filter { scores[$0.rawValue] == nil }
    }

    /// Axes that scored at or below the generic anchor, worst first.
    ///
    /// The actionable half of the score. "73/100" tells the reader the prompt is short of the bar
    /// and nothing about where; the axes that were actually marked down say what to fix, and unlike
    /// the weighted total they are not an aggregate of twelve noisy judgements. Ordered by score
    /// then by axis order, so two runs with the same marks name the axes in the same order.
    func weakestAxes(for target: PromptTarget, limit: Int = 3) -> [Axis] {
        // Only axes the critic actually marked. An omitted axis defaults to 2, the generic anchor,
        // so it appeared here as a measurement *and* in `missingAxes` as an assumption — the panel
        // printed "Scored without: Context, Inputs, Deliverable" and then "Below the bar: Context,
        // Inputs, Deliverable", presenting a default as a finding.
        Axis.applicable(to: target)
            .enumerated()
            .compactMap { i, axis in scores[axis.rawValue].map { (axis, i, $0.score) } }
            .filter { $0.2 <= 2 }
            .sorted { ($0.2, $0.1) < ($1.2, $1.1) }
            .prefix(limit)
            .map(\.0)
    }

    /// Weighted mean of the anchored scores, as a 0-100. This is a rubric score, not a probability
    /// of quality: the anchors are 0/2/4, so the gaps between them are conventions, not measurements.
    /// A missing axis scores 2 (the "generic" anchor); `missingAxes` names them.
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

    func missingAxes(for target: PromptTarget) -> [Axis] {
        Diagnosis(scores: scores).missingAxes(for: target)
    }

    /// Axes the critic marked at or below the generic anchor, worst first. See `Diagnosis`.
    func weakestAxes(for target: PromptTarget, limit: Int = 3) -> [Axis] {
        Diagnosis(scores: scores).weakestAxes(for: target, limit: limit)
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

    /// Case-insensitive, for the command line.
    ///
    /// `Rigor(rawValue:)` is exact, and the raw values are capitalised — so `--rigor deep` fell
    /// back to Fast and reported a one-call run as if it had been a Deep one. Silent, and in the
    /// direction that hides defects.
    static func parse(_ s: String) -> Rigor? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return allCases.first { $0.rawValue.lowercased() == t }
    }
}

struct ClarifyingQuestion: Identifiable, Hashable {
    let id = UUID()
    var question: String
    var why: String
    var options: [String]
    var answer = ""
    /// The answer the writer will assume if the user skips. Recorded under Assumptions.
    var `default` = ""
}
