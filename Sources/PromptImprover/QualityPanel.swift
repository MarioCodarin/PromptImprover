import SwiftUI
import PromptCore

/// Small score chip shown under the result: rubric score, structural score, test count.
struct QualityBadge: View {
    let text: String
    var body: some View {
        // Quiet mono meta, not a pill.
        Text(text)
            .font(.figure)
            .foregroundStyle(.tertiary)
            .help("Rubric is the critic's weighted judgement of twelve axes; its run-to-run spread "
                  + "on identical text is \(RubricNoise.measuredSpread) points, so read it as a band. "
                  + "Structure is the deterministic linter: same input, same score, every time.")
    }
}

/// The evidence behind the prompt: what the critic scored, what the linter caught, and the
/// acceptance tests when the run was deep enough to produce them.
struct QualityPanel: View {
    @EnvironmentObject var vm: ImproverViewModel
    @StateObject private var ui = QualityUI()

    var body: some View {
        if vm.lint != nil || vm.critique != nil {
            DisclosureGroup(isExpanded: $ui.open) {
                VStack(alignment: .leading, spacing: 12) {
                    scores
                    if let c = vm.critique { verdict(c) }
                    if let l = vm.lint { structure(l) }
                    if let s = vm.evalSuite { tests(s) }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(spacing: 6) {
                    // A status dot, not a coloured seal: it carries meaning, so it stays small.
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text("Quality").font(.ui)
                    if let line = vm.qualityLine {
                        Text(line).font(.figure).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider().opacity(0.5)
        }
    }

    private var tint: Color {
        guard let l = vm.lint else { return .secondary }
        if !l.blockers.isEmpty { return .bad }
        return l.isClean ? .ok : .warn
    }

    // MARK: Sections

    private var scores: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let c = vm.critique {
                // Labelled as a rubric score, not a quality percentage: the two 0-100 numbers on
                // this panel come from different instruments and one blocker costs each of them a
                // different amount.
                ScoreRow(label: "Rubric", value: c.total(for: vm.runTarget), suffix: "/100", lead: true,
                         help: "Weighted mean of the twelve axes the critic scored. The critic's own "
                             + "run-to-run spread on identical text is \(RubricNoise.measuredSpread) "
                             + "points, so treat this as a band and compare it with nothing.")
                // A missing axis silently scores the generic 2, so the number above is part
                // assumption. Naming them is the difference between a score and a guess.
                let absent = c.missingAxes(for: vm.runTarget)
                if !absent.isEmpty {
                    Text("Scored without: " + absent.map(\.title).joined(separator: ", "))
                        .font(.meta).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The part of the score a reader can act on. Twelve per-axis marks survive the
                // critic's noise far better than their weighted mean does, and naming them turns
                // "73" into "73, and here is what is dragging it".
                let weak = c.weakestAxes(for: vm.runTarget)
                if !weak.isEmpty {
                    Text("Below the bar: " + weak.map(\.title).joined(separator: ", "))
                        .font(.meta).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let l = vm.lint {
                ScoreRow(label: "Structure", value: l.score, suffix: "/100",
                         help: "Deterministic linter. Same input, same score, every time.")
                Text(l.summary).font(.meta).foregroundStyle(.secondary)
            }
            if let c = vm.critique, !c.strengths.isEmpty {
                Text("Working: " + c.strengths.joined(separator: " · "))
                    .font(.meta).foregroundStyle(.secondary)
            }
            // Cost is part of the result: a Deep run is five or six calls, and that is a decision.
            Text("\(vm.calls) model call\(vm.calls == 1 ? "" : "s") · \(String(format: "%.1f", vm.elapsed))s · \(vm.tokensIn) in / \(vm.tokensOut) out")
                .font(.figure)
                .foregroundStyle(.tertiary)
        }
    }

    private func verdict(_ c: Critique) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !c.summary.isEmpty {
                Text(c.summary).font(.ui)
            }
            // Positional identity, not `issue.id`. Identity derived from model text collides: two
            // issues on one axis with an omitted quote and problem produce the same string, and
            // SwiftUI's behaviour for duplicate ids is undefined. A list this short does not need
            // stable identity across updates.
            ForEach(Array(c.issues.enumerated()), id: \.offset) { _, issue in
                IssueRow(severity: issue.severity.rawValue,
                         title: "\(issue.axis) · \(issue.problem)",
                         detail: issue.quote.isEmpty ? issue.fix : "\u{201C}\(issue.quote)\u{201D} → \(issue.fix)")
            }
            if c.needsRepair, let note = repairNote {
                Text(note).font(.meta).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Says what happened to the repair, because the verdict alone is ambiguous: a prompt that still
    /// reads "repair" may have been repaired once already, or had its repair thrown away.
    private var repairNote: String? {
        switch vm.repairOutcome {
        case .applied: return "One repair pass was applied. What is listed above survived it — refine if you want it changed."
        case .reverted:
            // Name the reason: "discarded" alone leaves the user unable to tell a model failure
            // from the guard working correctly.
            let why = vm.repairNote.map { " \($0.prefix(1).uppercased())\($0.dropFirst())." } ?? ""
            return "A repair was attempted and discarded.\(why) The prompt below is the pre-repair text."
        case .none: return nil
        }
    }

    private func structure(_ l: PromptLinter.Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if l.issues.isEmpty {
                Text("No structural defects")
                    .font(.ui).foregroundStyle(.secondary)
            }
            ForEach(l.issues) { issue in
                IssueRow(severity: issue.severity.rawValue, title: issue.title, detail: issue.detail)
            }
        }
    }

    private func tests(_ s: EvalSuite) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Acceptance tests").font(.ui.weight(.medium))
                Spacer()
                Button(vm.copied ? "Copied" : "Copy tests") { vm.copyTests() }
                    .buttonStyle(QuietButtonStyle())
            }
            // Same reason as the issue list: two cases can share a name and an empty input.
            ForEach(Array(s.cases.enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name).font(.ui)
                    if !c.trap.isEmpty {
                        Text(c.trap).font(.meta).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

final class QualityUI: ObservableObject { @Published var open = false }

private struct ScoreRow: View {
    let label: String
    let value: Int
    let suffix: String
    /// The rubric is the one figure that carries the accent; the other rows are neutral steps.
    var lead = false
    var help: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.meta).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(lead ? Color.spark : Color.white.opacity(0.36))
                        .frame(width: max(2, geo.size.width * CGFloat(min(100, max(0, value))) / 100))
                }
            }
            .frame(height: 4)
            // Sizes to its own text. A fixed 52-point frame silently clipped "73/100 weighted"
            // mid-number, which is the worst possible thing to truncate on a score row.
            Text("\(value)\(suffix)")
                .font(.figure.weight(lead ? .medium : .regular))
                .foregroundStyle(lead ? Color.spark : Color.secondary)
                .fixedSize()
                .frame(minWidth: 52, alignment: .trailing)
        }
        .help(help ?? "")
    }
}

private struct IssueRow: View {
    let severity: String
    let title: String
    let detail: String

    var body: some View {
        // Severity as a proof mark in the margin: one mono letter in its colour, no filled tile.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(severity.prefix(1).uppercased())
                .font(.figure.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 12, alignment: .leading)
                .help(severity)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui)
                    .fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty {
                    Text(detail).font(.meta).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var color: Color {
        switch severity {
        case "blocker": return .bad
        case "major": return .warn
        default: return .secondary
        }
    }
}
