import SwiftUI

/// Small score chip shown under the result: rubric score, structural score, test count.
struct QualityBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .help("Rubric score is the critic's weighted judgement. Structure score is the deterministic linter.")
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
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(tint)
                    Text("Quality").font(.system(size: 12, weight: .medium))
                    if let line = vm.qualityLine {
                        Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().opacity(0.6)
        }
    }

    private var icon: String {
        guard let l = vm.lint else { return "checkmark.seal" }
        return l.isClean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var tint: Color {
        guard let l = vm.lint else { return .secondary }
        if !l.blockers.isEmpty { return .red }
        return l.isClean ? .green : .orange
    }

    // MARK: Sections

    private var scores: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let c = vm.critique {
                // Labelled as a rubric score, not a quality percentage: the two 0-100 numbers on
                // this panel come from different instruments and one blocker costs each of them a
                // different amount.
                ScoreRow(label: "Rubric", value: c.total(for: vm.runTarget), suffix: "/100 weighted")
                // A missing axis silently scores the generic 2, so the number above is part
                // assumption. Naming them is the difference between a score and a guess.
                let absent = c.missingAxes(for: vm.runTarget)
                if !absent.isEmpty {
                    Text("Scored without: " + absent.map(\.rawValue).joined(separator: ", "))
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            if let l = vm.lint {
                ScoreRow(label: "Structure", value: l.score, suffix: "/100")
                Text(l.summary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let c = vm.critique, !c.strengths.isEmpty {
                Text("Working: " + c.strengths.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // Cost is part of the result: a Deep run is five or six calls, and that is a decision.
            Text("\(vm.calls) model call\(vm.calls == 1 ? "" : "s") · \(String(format: "%.1f", vm.elapsed))s · \(vm.tokensIn) in / \(vm.tokensOut) out")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func verdict(_ c: Critique) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !c.summary.isEmpty {
                Text(c.summary).font(.system(size: 12))
            }
            ForEach(c.issues) { issue in
                IssueRow(severity: issue.severity.rawValue,
                         title: "\(issue.axis) · \(issue.problem)",
                         detail: issue.quote.isEmpty ? issue.fix : "\u{201C}\(issue.quote)\u{201D} → \(issue.fix)")
            }
            if c.needsRepair, let note = repairNote {
                Text(note).font(.system(size: 10.5)).foregroundStyle(.tertiary)
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
                Label("No structural defects.", systemImage: "checkmark")
                    .font(.system(size: 12)).foregroundStyle(.green)
            }
            ForEach(l.issues) { issue in
                IssueRow(severity: issue.severity.rawValue, title: issue.title, detail: issue.detail)
            }
        }
    }

    private func tests(_ s: EvalSuite) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Acceptance tests").font(.system(size: 12, weight: .medium))
                Spacer()
                Button(vm.copied ? "Copied" : "Copy tests") { vm.copyTests() }
                    .controlSize(.small)
            }
            ForEach(s.cases) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name).font(.system(size: 11, weight: .medium))
                    if !c.trap.isEmpty {
                        Text(c.trap).font(.system(size: 11)).foregroundStyle(.secondary)
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

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint.gradient)
                        .frame(width: max(2, geo.size.width * CGFloat(min(100, max(0, value))) / 100))
                }
            }
            .frame(height: 5)
            Text("\(value)\(suffix)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private var tint: Color {
        value >= 85 ? .green : (value >= 65 ? .yellow : .orange)
    }
}

private struct IssueRow: View {
    let severity: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(severity.prefix(1).uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(RoundedRectangle(cornerRadius: 3).fill(color))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var color: Color {
        switch severity {
        case "blocker": return .red
        case "major": return .orange
        default: return .secondary
        }
    }
}
