import Foundation

/// Deterministic checks over a written prompt.
///
/// The critic is a model and can be talked into anything; this linter is not. Everything here is
/// a fact about the text — a missing section, a shouted word, a format declared twice with
/// different answers — so the panel can show a hard failure even when the model says "ship".
///
/// Deliberately narrow: only checks where a string test is *sound*. Semantic contradictions
/// ("auto-assign before informing" vs "inform before assigning") are left to the critic, because
/// a word-overlap heuristic would flag "always run the tests" against "never commit without
/// running tests" and call agreement a conflict.
enum PromptLinter {

    struct Issue: Identifiable, Hashable {
        enum Severity: String, Comparable {
            case blocker, major, minor
            private var rank: Int {
                switch self { case .blocker: return 0; case .major: return 1; case .minor: return 2 }
            }
            static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
        }
        var id: String
        var severity: Severity
        var title: String
        var detail: String
        var fix: String

        /// Which rubric axis this check defends, so a lint-driven repair is told what the issue
        /// is about instead of guessing.
        ///
        /// Keyed on the section names `requiredSections` actually returns, not on a paraphrase of
        /// them. Two earlier versions of this table were wrong in different ways — one keyed on
        /// `section:` (a registry label, never an id), the next on single-word names while the
        /// sections are `"output contract"` and `"success criteria"` — and both made every
        /// section blocker report `consistency`, the axis that means "contradiction", so a repair
        /// was sent looking for a contradiction when the prompt was simply missing a heading.
        /// A self-test asserts every emitted id resolves to its own axis.
        var axis: String {
            // Section checks emit `missing-<section>`.
            if id.hasPrefix("missing-") {
                switch id.dropFirst("missing-".count) {
                case "objective", "purpose": return "goal"
                case "context": return "context"
                case "inputs": return "inputs"
                case "requirements": return "procedure"
                case "behaviour": return "consistency"
                case "boundaries": return "constraints"
                case "output contract": return "deliverable"
                case "success criteria": return "criteria"
                case "verification": return "verification"
                case "assumptions": return "robustness"
                case "autonomy": return "autonomy"
                default: return "consistency"
                }
            }
            // `limit-conflict-words` and friends carry the unit as a suffix.
            if id.hasPrefix("limit-conflict") { return "consistency" }
            switch id {
            case "format-conflict": return "consistency"
            case "vague-criteria": return "criteria"
            case "placeholders", "too-short", "too-long": return "deliverable"
            case "fence", "preamble", "filler", "shouting", "meta", "executed", "copy":
                return "economy"
            case "unbounded": return "constraints"
            case "silent-defaults": return "robustness"
            default: return "consistency"
            }
        }

        /// The same issue in the shape the repair stage already consumes. The linter has no
        /// quote, so the title and detail carry the problem instead.
        var asCritiqueIssue: CritiqueIssue {
            let mapped: Defect.Severity
            switch severity {
            case .blocker: mapped = .blocker
            case .major: mapped = .major
            case .minor: mapped = .minor
            }
            return CritiqueIssue(axis: axis, severity: mapped, quote: "",
                                 problem: "\(title): \(detail)", fix: fix)
        }
    }

    struct Report {
        var issues: [Issue] = []
        var passed: [String] = []
        var checksRun = 0

        var blockers: [Issue] { issues.filter { $0.severity == .blocker } }
        var majors: [Issue] { issues.filter { $0.severity == .major } }
        var minors: [Issue] { issues.filter { $0.severity == .minor } }
        var isClean: Bool { blockers.isEmpty && majors.isEmpty }

        /// 100 minus weighted penalties. A blocker is not a style note: it drops the score hard.
        var score: Int {
            var s = 100
            for i in issues {
                switch i.severity {
                case .blocker: s -= 25
                case .major: s -= 10
                case .minor: s -= 3
                }
            }
            return max(0, s)
        }

        var summary: String {
            if issues.isEmpty { return "All \(checksRun) structural checks passed." }
            let b = blockers.count, m = majors.count, n = minors.count
            var parts: [String] = []
            if b > 0 { parts.append("\(b) blocker\(b == 1 ? "" : "s")") }
            if m > 0 { parts.append("\(m) major") }
            if n > 0 { parts.append("\(n) minor") }
            return parts.joined(separator: ", ") + " of \(checksRun) checks"
        }
    }

    // MARK: - Entry point

    static func lint(_ prompt: String, target: PromptTarget, unansweredQuestions: Int, draft: String = "") -> Report {
        var r = Report()
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            r.checksRun = 1
            r.issues = [Issue(id: "empty", severity: .blocker, title: "Empty output",
                              detail: "The model returned nothing.", fix: "Run it again, or switch model.")]
            return r
        }

        // Every rule takes the same context. Adding a check is one function in `LinterChecks`
        // plus one line in the registry below.
        let ctx = LintContext(text: text, lines: text.components(separatedBy: "\n"), target: target,
                              unansweredQuestions: unansweredQuestions, draft: draft)

        func check(_ name: String, _ fail: () -> Issue?) {
            r.checksRun += 1
            if let issue = fail() { r.issues.append(issue) } else { r.passed.append(name) }
        }

        check("no-fence")             { LinterChecks.fence(ctx) }
        check("no-preamble")          { LinterChecks.preamble(ctx) }
        for (name, issue) in LinterChecks.sections(ctx) {
            check("section:\(name)") { issue }
        }
        check("criteria-measurable")  { LinterChecks.criteria(ctx) }
        check("no-filler")            { LinterChecks.filler(ctx) }
        check("no-shouting")          { LinterChecks.shouting(ctx) }
        check("placeholders")         { LinterChecks.placeholders(ctx) }
        check("assumptions-when-unanswered") { LinterChecks.assumptions(ctx) }
        check("one-output-format")    { LinterChecks.formats(ctx) }
        check("one-limit-per-unit")   { LinterChecks.limits(ctx) }
        check("no-meta")              { LinterChecks.meta(ctx) }
        check("length")               { LinterChecks.length(ctx) }
        check("rewritten-not-copied") { LinterChecks.copy(ctx) }
        check("bounded-effort")       { LinterChecks.effort(ctx) }
        check("instructs-not-executes") { LinterChecks.executed(ctx) }


        r.issues.sort { $0.severity < $1.severity }
        return r
    }

    // MARK: - Helpers

    /// The title of a line that opens a section, or nil for ordinary content.
    ///
    /// Two forms count. A `#`-heading is the markdown one. A line wrapped entirely in emphasis —
    /// `**Objective**` — is a heading in everything but the hash marks, and demanding `##` reported
    /// five missing sections and a score of 0 on a hand-written prompt that had all five.
    ///
    /// Both forms are always accepted. An earlier version accepted emphasis only in documents with
    /// no `#` heading at all, which meant a document with a title (`# Add a retry budget`) and bold
    /// sections still scored 0 — the commonest shape a model produces, and the exact case the rule
    /// exists for. The sub-title problem that motivated the gate is solved in `sectionBody`, where
    /// it belongs: a section ends at the next heading that names a *different known section*, so a
    /// bolded `**Quality bar**` inside Success criteria is content rather than a terminator.
    static func headingTitle(of line: String) -> (title: String, depth: Int)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("#") {
            let depth = t.prefix(while: { $0 == "#" }).count
            return (t.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased(), depth)
        }
        // A bullet is content, even when the whole bullet is bold.
        guard !t.hasPrefix("- ") && !t.hasPrefix("* ") && !t.hasPrefix("\u{2022} ") else { return nil }
        // The title is the leading emphasised span, whether or not the line ends there. Models
        // routinely write `**Objective** Stop the sender from dropping events.` — title and first
        // sentence on one line — and accepting only a whole-line emphasis scored that shape 0.
        let marks = t.hasPrefix("**") ? "**" : t.hasPrefix("__") ? "__"
            : t.hasPrefix("*") ? "*" : t.hasPrefix("_") ? "_" : nil
        guard let marks,
              let close = t.range(of: marks, range: t.index(t.startIndex, offsetBy: marks.count)..<t.endIndex)
        else { return nil }
        let title = String(t[t.index(t.startIndex, offsetBy: marks.count)..<close.lowerBound])
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !title.isEmpty, title.count <= 48,
              !title.contains("."), !title.contains(","), !title.contains("?") else { return nil }
        return (title, 1)
    }

    /// Every keyword that names a section, across every target.
    ///
    /// `sectionBody` needs to know whether a heading begins *some* section, not whether it begins
    /// the one being captured. A title that names no section is a sub-heading and stays inside.
    static let sectionVocabulary: [String] = {
        var seen: [String] = []
        for target in [PromptTarget.agentTask, .systemPrompt, .chat] {
            for (_, alternatives) in requiredSections(for: target) {
                for a in alternatives where !seen.contains(a) { seen.append(a) }
            }
        }
        // Sections the skeleton offers that no target strictly requires, so a bolded one still
        // terminates the section above it instead of being swallowed as content.
        for extra in ["input", "constraint", "non-goal", "verification", "priorit",
                      "autonomy", "escalation", "assumption", "default", "decision", "note"] {
            if !seen.contains(extra) { seen.append(extra) }
        }
        return seen
    }()

    static func headings(_ lines: [String]) -> [String] {
        lines.compactMap { headingTitle(of: $0)?.title }
    }

    /// A labelled line — "Purpose: …", "**Output contract:** …" — carries the same structural
    /// signal as a heading, and a writer that uses one has organised the prompt. Requiring the
    /// `##` form failed a correct system prompt that opened "Purpose: You are building…".
    /// Only the label before the colon counts, so ordinary prose cannot satisfy it.
    static func labels(_ lines: [String]) -> [String] {
        lines.compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            // A list item is an entry, not a section title — unless it is a labelled one.
            // "`- Objective: …`" is a real way to write a section list, and rejecting the whole
            // bullet made every section in that shape invisible.
            let bulleted = t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("\u{2022} ")
            let body = bulleted ? t.dropFirst(2).trimmingCharacters(in: .whitespaces) : t
            let bare = body.drop { "*_#>".contains($0) }
                .trimmingCharacters(in: .whitespaces)
            guard let colon = bare.firstIndex(of: ":") else { return nil }
            let label = bare[..<colon]
                .trimmingCharacters(in: CharacterSet(charactersIn: "*_ "))
                .lowercased()
            // A label is a short noun phrase, not a clause.
            guard !label.isEmpty, label.count <= 24, !label.contains(",") else { return nil }
            // A label that denies the section is not evidence of one. `contains` accepts any label
            // holding a keyword, so "No output format: produce whatever reads best" satisfied the
            // output contract while saying there is none.
            let denials = ["no ", "not ", "never ", "without ", "zero ", "n/a"]
            guard !denials.contains(where: { label.hasPrefix($0) }) else { return nil }
            return label
        }
    }

    /// Body of the first section whose heading matches any keyword, up to the next heading.
    static func sectionBody(_ lines: [String], matching keywords: [String]) -> String {
        var capturing = false
        var out: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let h = headingTitle(of: line) {
                if capturing {
                    // A heading ends the section only when it names a *different* section. Ending
                    // at the next heading of any kind made a bolded sub-title inside a section —
                    // `**Quality bar**` above the criteria — empty the body, which silently
                    // switched off every check that reads it. A title that names no section is a
                    // sub-heading and belongs to the section above it.
                    let namesThis = keywords.contains { h.title.contains($0) }
                    let namesOther = sectionVocabulary.contains { h.title.contains($0) }
                    if namesThis || !namesOther { continue }
                    break
                }
                if keywords.contains(where: { h.title.contains($0) }) { capturing = true }
                continue
            }
            if capturing { out.append(t) }
        }
        return out.joined(separator: "\n")
    }

    static func requiredSections(for target: PromptTarget) -> [(String, [String])] {
        switch target {
        case .agentTask:
            return [("objective", ["goal", "objective", "purpose", "task"]),
                    ("context", ["context", "background", "situation"]),
                    ("requirements", ["requirement", "instructions", "what to do", "approach", "procedure", "steps"]),
                    ("output contract", ["deliverable", "output", "format", "report"]),
                    ("success criteria", ["success", "acceptance", "done", "criteria", "quality bar"])]
        case .systemPrompt:
            return [("purpose", ["purpose", "role", "mission", "who you are"]),
                    ("behaviour", ["behavior", "behaviour", "rules", "guidelines", "how you work", "principles"]),
                    ("output contract", ["output", "format", "style", "tone", "response"])]
        case .chat:
            // A chat message is prose, so its elements are matched anywhere in the text rather than
            // at headings. There is deliberately no "objective" entry: in a chat message the opening
            // line *is* the objective, and every keyword test for it flagged correct messages
            // ("Write a resignation email that…" contains none of the words). Length, output
            // contract, filler and limit checks carry the rest.
            // A verb is not a contract: "Can you write something that fixes it?" contains "write"
            // and constrains nothing. What pins a chat message's output is a length bound or an
            // explicit exclusion, so those are what this requires.
            return [("output contract", ["words", "sentences", "paragraphs", "bullets", "lines",
                                         "no preamble", "no sign-off", "no closing",
                                         "do not include", "don't include", "without",
                                         "exclude", "avoid", "at most", "at least",
                                         "one paragraph", "plain prose", "a numbered list"])]
        }
    }

    static func lengthBounds(for target: PromptTarget) -> (min: Int, max: Int) {
        switch target {
        case .agentTask: return (60, 1400)
        case .systemPrompt: return (50, 1100)
        // A chat turn is one sentence by nature: "Summarise the attached report in three bullets,
        // plain prose, no preamble" is complete at eleven words. The floor was 30, which flagged
        // most casual chat messages. A contentless one is still caught — by the output-contract
        // check, which is the sound test for "this constrains nothing".
        // 30, not 8. The floor was lowered to admit a terse but complete chat request, and it
        // also admitted "Can you help me with this thing, under 100 words please?" — contentless,
        // and it clears the output-contract check on the word "words" alone, so nothing else
        // catches it. A chat message that says less than this is genuinely missing something.
        case .chat: return (30, 500)
        }
    }

    private static func count(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var n = 0, start = haystack.startIndex
        while let r = haystack.range(of: needle, range: start..<haystack.endIndex) {
            n += 1
            start = r.upperBound
        }
        return n
    }

    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into", "your", "you", "are", "was", "were",
        "will", "shall", "must", "should", "can", "may", "not", "but", "all", "any", "each", "every",
        "when", "then", "than", "there", "their", "them", "they", "have", "has", "had", "been", "being",
        "about", "which", "what", "who", "how", "why", "where", "use", "used", "using", "make", "made",
        "also", "only", "just", "very", "more", "most", "some", "such", "like", "one", "two", "its",
        "it", "is", "be", "as", "at", "by", "in", "of", "on", "or", "to", "a", "an", "do", "does", "did",
    ]

    static func contentWords(_ text: String) -> Set<String> {
        var out: Set<String> = []
        let scalars = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        for w in String(scalars).split(whereSeparator: \.isWhitespace) where w.count >= 3 {
            let s = String(w)
            if !stopwords.contains(s) { out.insert(s) }
        }
        return out
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let inter = a.intersection(b).count
        return Double(inter) / Double(a.union(b).count)
    }
}
