import Foundation

/// Decides whether a repair is worth shipping.
///
/// The first version compared only the weighted structural score, which is the wrong instrument:
/// a repair that closes a contradiction the linter cannot see and adds two words past a ceiling
/// scores three points lower and is still the better prompt. It was discarded, and the user
/// shipped the contradiction the repair had just fixed.
///
/// The guard asks what actually changed instead. Only blockers and majors can veto, because those
/// are the severities that make a prompt unusable; minors are polish, and the critic re-scores the
/// shipped text anyway. A pure function over two reports, so the rule is testable without a model.
enum RepairGuard {

    enum Reason: String, Equatable {
        case empty = "the repair returned nothing"
        case gainedBlocker = "it introduced a blocker"
        case brokeClean = "the prompt was clean before the repair"
        case gainedMajor = "it left more major defects than it fixed"
    }

    enum Verdict: Equatable {
        case accept
        case revert(Reason)

        var isRevert: Bool {
            if case .revert = self { return true }
            return false
        }

        /// One line for the panel, or nil when the repair was accepted.
        var note: String? {
            if case .revert(let reason) = self { return reason.rawValue }
            return nil
        }
    }

    /// A stable name for the defect an entry is about, so the critic's list and the gate's can be
    /// compared. The gate names its finding in `problem` ("Missing output contract section: …") and
    /// the critic quotes the text, so an id-based comparison never matched anything.
    static func defectKey(_ issue: CritiqueIssue) -> String {
        // Normalise the separators first: the gate writes "Missing output contract section: …"
        // and an id-shaped spelling is "missing-output contract". Both name the same defect.
        let text = issue.problem.lowercased().replacingOccurrences(of: "-", with: " ")
        if let range = text.range(of: "missing ") {
            let name = text[range.upperBound...]
                .split(whereSeparator: { !$0.isLetter })
                .prefix { $0 != "section" }
                .joined(separator: " ")
            if !name.isEmpty { return "missing:" + name }
        }
        return issue.axis + ":" + String(text.prefix(48))
    }

    /// What the repair stage should fix: the critic's quoted issues, plus any blocker or major the
    /// gate found that the critic did not report.
    ///
    /// Two reviewers measure different things and only the gate is deterministic, so a prompt the
    /// linter rejects must not ship because the critic said "ship". Minors are excluded from the
    /// gate's contribution: they are polish, and churning on them costs a call for no change in
    /// whether the prompt is usable.
    static func issues(critique: Critique, lint: PromptLinter.Report?) -> [CritiqueIssue] {
        var out = critique.needsRepair ? critique.issues : []
        guard let lint, !lint.isClean else { return out }
        // Keyed on the defect the entry names, not on `CritiqueIssue.id`: the gate has no quote
        // and the critic's problem text never matches the gate's title, so an id-based set removed
        // nothing and the repair prompt showed the same defect twice.
        var known = Set(out.map(defectKey))
        out += lint.issues
            .filter { $0.severity != .minor }
            .map(\.asCritiqueIssue)
            .filter { entry in
                let key = defectKey(entry)
                guard !known.contains(key) else { return false }
                known.insert(key)
                return true
            }
        return out
    }

    /// Severity-weighted defect load. Used for the panel's explanation, not for the verdict.
    static func load(_ r: PromptLinter.Report) -> Int {
        r.blockers.count * 100 + r.majors.count * 10 + r.minors.count
    }

    /// - Parameters:
    ///   - before: the report for the text that was sent for repair.
    ///   - after: the report for the text the repair returned.
    ///   - revised: the repaired text, so emptiness is decided here rather than by every caller.
    static func judge(before: PromptLinter.Report, after: PromptLinter.Report, revised: String) -> Verdict {
        if revised.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .revert(.empty)
        }
        // Most specific reason first, so the panel names the real cause.
        if after.blockers.count > before.blockers.count {
            return .revert(.gainedBlocker)
        }
        // A prompt that was clean and now carries a major was damaged, whatever else improved.
        if before.isClean, !after.isClean {
            return .revert(.brokeClean)
        }
        if after.majors.count > before.majors.count {
            return .revert(.gainedMajor)
        }
        // Minors never veto: the repair was asked to fix something the linter cannot see, and
        // rejecting it over polish would ship the thing it was asked to fix.
        return .accept
    }
}
