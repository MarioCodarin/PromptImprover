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

        let lines = text.components(separatedBy: "\n")
        let headings = self.headings(lines)
        let lower = text.lowercased()

        func check(_ name: String, _ fail: () -> Issue?) {
            r.checksRun += 1
            if let issue = fail() { r.issues.append(issue) } else { r.passed.append(name) }
        }

        // 1. Not wrapped in a code fence.
        check("no-fence") {
            guard lines.count >= 3 else { return nil }
            let fenceLines = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            guard fenceLines.first == 0, fenceLines.last == lines.count - 1, fenceLines.count == 2 else { return nil }
            return Issue(id: "fence", severity: .major, title: "Wrapped in a code fence",
                         detail: "The whole prompt sits inside ``` fences, so it cannot be pasted as instructions.",
                         fix: "Strip the outer fence.")
        }

        // 2. No chat preamble.
        check("no-preamble") {
            let first = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            // "Here is the CSV of orders, find the three regions…" is a chat message doing its job.
            // The chatter that has to be caught is the model addressing the user about the task.
            let openers = target == .chat
                ? ["sure", "certainly", "of course", "absolutely", "great", "okay", "ok,"]
                : ["sure", "certainly", "of course", "absolutely", "here's", "here is", "here are",
                   "great", "okay", "ok,"]
            guard openers.contains(where: { first.hasPrefix($0) }) else { return nil }
            return Issue(id: "preamble", severity: .major, title: "Starts with chat preamble",
                         detail: "First line: \u{201C}\(first.prefix(60))\u{201D}",
                         fix: "The output must start with the prompt itself, usually its title.")
        }

        // 3. Required sections for the target.
        for (name, alternatives) in requiredSections(for: target) {
            check("section:\(name)") {
                // A chat message is prose: it has no headings, so its required elements are matched
                // against the body. Demanding markdown structure of a chat message flagged every
                // well-formed one as broken.
                let found = target == .chat
                    ? alternatives.contains { lower.contains($0) }
                    : headings.contains { h in alternatives.contains(where: { h.contains($0) }) }
                guard !found else { return nil }
                let near = target == .chat ? "passage" : "heading"
                let where_ = target == .chat ? "Say it in the message" : "Add the \(name) section, or rename the existing one so it is recognisable"
                return Issue(id: "missing-\(name)", severity: .blocker,
                             title: "Missing \(name) section",
                             detail: "No \(near) matches \(alternatives.joined(separator: " / ")).",
                             fix: "\(where_).")
            }
        }

        // 4. Success criteria must be checkable, not adjectives.
        check("criteria-measurable") {
            let body = sectionBody(lines, matching: ["success", "acceptance", "done", "criteria", "definition of done", "quality"])
            guard !body.isEmpty else { return nil }   // absence is already a blocker above
            let measurable = ["pass", "return", "contain", "equal", "match", "at least", "no more than",
                              "within", "under ", "≤", "≥", "%", "command", "test", "field", "verify",
                              "check", "exit code", "grep", "diff", "count"]
            // A digit only counts as a measurement if it is part of a number, not an ordered-list
            // marker: "1. It should be high quality" used to satisfy this check.
            let hasNumber = body.split(whereSeparator: \.isWhitespace).contains { token in
                let raw = String(token)
                // "1." and "2)" are list markers. Test the raw token first: trimming the dot was
                // what made "1. It should be high quality" pass as a measurement.
                let bare = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]"))
                if raw.hasSuffix(".") || raw.hasSuffix(")") {
                    if bare.allSatisfy(\.isNumber) { return false }
                }
                guard bare.contains(where: \.isNumber) else { return false }
                // "5" / "250" / "4.5" / "1,000" / "90%" are measurements.
                if bare.allSatisfy(\.isNumber) { return true }
                if bare.filter(\.isNumber).count >= 2 { return true }
                return Double(bare) != nil
            }
            let hasVerb = measurable.contains { body.lowercased().contains($0) }
            guard !(hasNumber || hasVerb) else { return nil }
            return Issue(id: "vague-criteria", severity: .major, title: "Success criteria are not checkable",
                         detail: "The criteria section contains no threshold, command, field or verifiable verb.",
                         fix: "Rewrite each criterion as something a second person could run or read.")
        }

        // 5. Filler and persona theatre.
        check("no-filler") {
            let banned = ["world-class", "world class", "you are an expert", "as an ai", "cutting-edge",
                          "state-of-the-art", "best-in-class", "think outside the box", "unleash",
                          "you will be penalized", "this is critical", "it is crucial that you"]
            let hits = banned.filter { lower.contains($0) }
            guard !hits.isEmpty else { return nil }
            return Issue(id: "filler", severity: .minor, title: "Filler phrases",
                         detail: hits.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "),
                         fix: "Delete them. They cost attention and steer nothing.")
        }

        // 6. Shouting.
        check("no-shouting") {
            let allow: Set<String> = ["API", "JSON", "CSV", "HTML", "CSS", "SQL", "HTTP", "HTTPS", "URL", "URLS",
                                      "CLI", "SDK", "PDF", "XML", "YAML", "TODO", "README", "LLM", "LLMS", "ID",
                                      "IDS", "OK", "GPT", "UI", "UX", "CI", "CD", "MCP", "NDA", "SLA", "ISO",
                                      "UTC", "GMT", "EUR", "USD", "AI", "RAG", "TDD", "PR", "PRS", "EU", "US",
                                      "UK", "GPU", "CPU", "RAM", "OS", "SQL", "JWT", "OATH", "ACL", "CRUD"]
            // Strip the places where caps are structural rather than emphatic: {{PLACEHOLDERS}},
            // `code spans` and fenced blocks. {{LAST DAY}} is not shouting, it is a fill-in field.
            let scannable = text
                .replacingOccurrences(of: "\\{\\{[^}]*\\}\\}", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
            // Identifiers are not emphasis: ERROR_CODE, GET, PATCH and the `LINE` in `file.go:LINE`
            // are names. Only all-caps words in running prose count as shouting.
            let shouted = scannable.split(whereSeparator: { !($0.isLetter || $0 == "-") })
                .map(String.init)
                .filter { w in
                    guard w.count >= 4, w == w.uppercased(), w != w.lowercased() else { return false }
                    guard !allow.contains(w) else { return false }
                    // Underscore or digits anywhere nearby means it came from an identifier.
                    return true
                }
                .filter { w in !scannable.contains("\(w)_") && !scannable.contains("_\(w)") }
            guard shouted.count >= 3 else { return nil }
            return Issue(id: "shouting", severity: .minor, title: "ALL-CAPS emphasis",
                         detail: "\(shouted.count) shouted words, e.g. \(shouted.prefix(3).joined(separator: ", ")).",
                         fix: "Use plain emphasis, or say why the rule matters.")
        }

        // 7. Placeholder hygiene.
        check("placeholders") {
            // Occurrences, not marker kinds: a prompt with ten [TBD: …] slots is ten unfilled slots.
            let braces = count(of: "{{", in: text)
            let markers = ["[insert", "<insert", "[tbd", "xxx", "todo:"].reduce(0) { $0 + count(of: $1, in: lower) }
            let total = braces + markers
            guard total > 6 else { return nil }
            return Issue(id: "placeholders", severity: .major, title: "Too many placeholders",
                         detail: "\(total) unfilled slots. A prompt that is half placeholders is not a prompt yet.",
                         fix: "Fill the ones you know and move the rest into Assumptions with a default.")
        }

        // 8. Unanswered questions must surface as assumptions, not vanish.
        check("assumptions-when-unanswered") {
            guard unansweredQuestions > 0 else { return nil }
            // A heading with nothing under it is the failure this check exists to catch.
            let body = sectionBody(lines, matching: ["assumption", "defaults", "decisions"])
            let hasSection = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasInline = lower.contains("i assumed") || lower.contains("default:")
            guard !(hasSection || hasInline) else { return nil }
            return Issue(id: "silent-defaults", severity: .major,
                         title: "\(unansweredQuestions) question\(unansweredQuestions == 1 ? "" : "s") left unanswered, no assumptions listed",
                         detail: "The prompt silently picks defaults the user never saw.",
                         fix: "Add an Assumptions section naming the default chosen for each open question.")
        }

        // 9. Two different output formats declared.
        check("one-output-format") {
            let formats = ["json", "markdown", "csv", "yaml", "xml", "table", "bullet", "prose", "html"]
            let declared = formats.filter { f in
                lower.contains("output \(f)") || lower.contains("as \(f)") || lower.contains("in \(f)") || lower.contains("format: \(f)")
            }
            guard declared.count > 1, !lower.contains(" or "), !lower.contains("either") else { return nil }
            return Issue(id: "format-conflict", severity: .major, title: "Conflicting output formats",
                         detail: "Declares \(declared.joined(separator: ", ")) without an either/or.",
                         fix: "Pick one format, or state which conditions choose between them.")
        }

        // 10. Two different limits on the same *global* budget.
        //
        // Restricted to units that describe the whole deliverable. "3 bullets" in one section and
        // "5 bullets" in another is normal; "under 250 words" and "at least 600 words" is not.
        check("one-limit-per-unit") {
            let globalUnits = ["words", "characters", "pages", "lines"]
            let lowerBound = ["min", "minimum", "at least", "no fewer than", "fewer than", "over", "above", "≥", "from"]
            let upperBound = ["max", "maximum", "under", "at most", "no more than", "below", "limit", "≤", "up to"]
            let anyBound = lowerBound + upperBound + ["between", "roughly", "about", "around", "approx"]
            for unit in globalUnits {
                var lows: [Int] = [], highs: [Int] = []
                for line in lines {
                    let lowerLine = line.lowercased()
                    guard anyBound.contains(where: { lowerLine.contains($0) }) else { continue }
                    // "1,000 words" is one thousand, not zero.
                    let cleaned = lowerLine.replacingOccurrences(of: ",", with: "")
                    let tokens = cleaned.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
                    for (i, w) in tokens.enumerated() where w == unit || w == String(unit.dropLast()) {
                        guard i > 0, let n = Int(tokens[i - 1]) else { continue }
                        // Classify by the bound word nearest the number, not by the unit alone:
                        // "at least 250 words … at most 600 words" is a range, not a conflict.
                        let context = tokens[max(0, i - 4)..<i].joined(separator: " ")
                        if lowerBound.contains(where: { context.contains($0) }) { lows.append(n) }
                        else if upperBound.contains(where: { context.contains($0) }) { highs.append(n) }
                    }
                }
                // Only an unsatisfiable pair is a conflict: a floor above a ceiling. Two ceilings
                // ("under 1,000 words" and "at most 1,400") or two floors are redundant, and the
                // tighter one simply wins — flagging those punished prompts that were merely careful.
                guard let lo = lows.max(), let hi = highs.min(), lo > hi else { continue }
                let unique = Array(Set([lo, hi])).sorted()
                let adjective = ["words": "word", "characters": "character",
                                 "pages": "page", "lines": "line"][unit] ?? unit
                return Issue(id: "limit-conflict-\(unit)", severity: .major,
                             title: "Conflicting \(adjective) limits",
                             detail: "Both \(unique.map(String.init).joined(separator: " and ")) \(unit) appear as hard limits on the whole deliverable.",
                             fix: "Keep one number, or say which part of the deliverable each applies to.")
            }
            return nil
        }

        // 11. No meta commentary.
        check("no-meta") {
            let meta = ["i will now", "i've written", "this prompt is designed", "hope this helps", "let me know if"]
            let hit = meta.first { lower.contains($0) }
            guard let hit else { return nil }
            return Issue(id: "meta", severity: .major, title: "Model talks about the prompt",
                         detail: "\u{201C}\(hit)\u{201D}",
                         fix: "Strip commentary. The deliverable is the prompt.")
        }

        // 12. Length envelope per target.
        check("length") {
            let words = text.split(whereSeparator: \.isWhitespace).count
            let bounds = lengthBounds(for: target)
            if words < bounds.min {
                let article = target == .agentTask ? "an" : "a"
                return Issue(id: "too-short", severity: .major,
                             title: "Too thin for \(article) \(target.rawValue.lowercased())",
                             detail: "\(words) words; a usable one usually needs at least \(bounds.min).",
                             fix: "Add the missing sections rather than padding existing ones.")
            }
            if words > bounds.max {
                return Issue(id: "too-long", severity: .minor, title: "Longer than it needs to be",
                             detail: "\(words) words; past ~\(bounds.max) compliance drops.",
                             fix: "Cut restatement and merge rules that share a reason.")
            }
            return nil
        }

        // 13. Not a copy of the draft.
        check("rewritten-not-copied") {
            guard !draft.isEmpty else { return nil }
            let overlap = jaccard(contentWords(draft), contentWords(text))
            guard overlap > 0.8 else { return nil }
            return Issue(id: "copy", severity: .minor, title: "Mostly the original draft",
                         detail: "\(Int(overlap * 100))% of the draft's content words are unchanged.",
                         fix: "The value is in structure, criteria and constraints. Rewrite, don't reformat.")
        }

        // 14. Unbounded effort words.
        check("bounded-effort") {
            let vague = ["as much as possible", "as needed", "if necessary", "as appropriate", "be thorough",
                         "be comprehensive", "extensively", "in depth", "when relevant", "where applicable"]
            let hits = vague.filter { lower.contains($0) }
            guard !hits.isEmpty else { return nil }
            return Issue(id: "unbounded", severity: .minor, title: "Unbounded effort",
                         detail: hits.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "),
                         fix: "Replace with a bound: how many, how long, until what condition.")
        }

        // 15. Task executed instead of instructed.
        check("instructs-not-executes") {
            let fences = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count / 2
            let words = text.split(whereSeparator: \.isWhitespace).count
            guard fences >= 2, words > 250 else { return nil }
            return Issue(id: "executed", severity: .minor, title: "Looks like the task was performed",
                         detail: "\(fences) code blocks in a \(words)-word output.",
                         fix: "The deliverable is instructions. Keep only examples that teach a format.")
        }

        r.issues.sort { $0.severity < $1.severity }
        return r
    }

    // MARK: - Helpers

    private static func headings(_ lines: [String]) -> [String] {
        lines.compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#") else { return nil }
            return t.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        }
    }

    /// Body of the first section whose heading matches any keyword, up to the next heading.
    private static func sectionBody(_ lines: [String], matching keywords: [String]) -> String {
        var capturing = false
        var captureDepth = 0
        var out: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                let depth = t.prefix(while: { $0 == "#" }).count
                let h = t.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
                if capturing {
                    // A deeper heading belongs to this section; a same-or-shallower one ends it.
                    // Stopping at the first subheading reported "## Success criteria / ### Quality"
                    // as an empty section, and failed prompts that had written the content.
                    if depth > captureDepth { continue }
                    break
                }
                if keywords.contains(where: { h.contains($0) }) {
                    capturing = true
                    captureDepth = depth
                }
                continue
            }
            if capturing { out.append(t) }
        }
        return out.joined(separator: "\n")
    }

    private static func requiredSections(for target: PromptTarget) -> [(String, [String])] {
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
            return [("output contract", ["format", "return", "respond", "output", "write", "produce",
                                         "give me", "reply", "answer", "draft", "sentence", "paragraph"])]
        }
    }

    private static func lengthBounds(for target: PromptTarget) -> (min: Int, max: Int) {
        switch target {
        case .agentTask: return (120, 1400)
        case .systemPrompt: return (90, 1100)
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
