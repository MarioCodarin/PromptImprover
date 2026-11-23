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
            .help("Structure is the deterministic linter: same input, same score, every time. "
                  + "Review (Deep) lists quoted defects the linter cannot see, such as invented facts.")
    }
}

/// The evidence behind the prompt: what the review found, what the linter caught, and the
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
            // The review reports quoted issues, not a score: a weighted mean of twelve model
            // judgements moved 17 points between identical runs, so it is no longer computed.
            if let c = vm.critique {
                Text(c.issues.isEmpty ? "Review: no defects found"
                                      : "Review: \(c.issues.count) issue\(c.issues.count == 1 ? "" : "s") found")
                    .font(.ui)
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
            // Standard repairs from the linter alone, so the outcome is shown with or without a review.
            if let note = repairNote {
                Text(note).font(.meta).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if vm.timedOut {
                Text("The run reached its time limit. The prompt is complete; the stages after it did not run.")
                    .font(.meta).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Cost is part of the result.
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
        }
    }

    /// Says what happened to the repair, because the verdict alone is ambiguous: a prompt that still
    /// reads "repair" may have been repaired once already, or had its repair thrown away.
    private var repairNote: String? {
        switch vm.repairOutcome {
        case .applied: return "One repair pass was applied. Review issues, if any, describe the text before it — refine if you want more changed."
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
