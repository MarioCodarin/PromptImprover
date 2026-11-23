import Foundation

/// The data that flows between stages: what the analyzer reports, what the critic
/// reports, what the eval suite contains, and how deep a run goes.

struct Finding: Identifiable, Hashable {
    var code: String
    var severity: Defect.Severity
    var quote: String
    var fix: String

    var id: String { code + quote }

    /// Resolve a model-supplied axis name to an axis.
    ///
    /// Models return "output contract" for `deliverable` and "success criteria" for `criteria`.
    /// Before this, an unrecognised key silently scored that axis at the generic 2 with no trace,
    /// so a misnamed axis cost 3-4 points on the 0-100 and nobody could see why.
    static func match(_ raw: String) -> Axis? {
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

struct ClarifyingQuestion: Identifiable, Hashable {
    let id = UUID()
    var question: String
    var why: String
    var options: [String]
    var answer = ""
    /// The answer the writer will assume if the user skips. Recorded under Assumptions.
    var `default` = ""
}
