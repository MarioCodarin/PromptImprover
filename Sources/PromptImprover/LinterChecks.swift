import Foundation

/// Everything a check is allowed to look at. One value, computed once per lint, so a check cannot
/// quietly re-derive a property differently from its neighbour — the previous inline version had
/// `let words` declared twice in two checks with two different definitions.
///
/// `wordTokens` is named for what it is (an array) rather than `words`, so a check that wants a
/// count declares one and no reader has to work out which meaning is in scope.
struct LintContext {
    /// The prompt with outer whitespace trimmed.
    let text: String
    /// `text` split on newlines.
    let lines: [String]
    /// The target this prompt is judged against.
    let target: PromptTarget
    /// How many of the analyzer's questions the user left blank.
    let unansweredQuestions: Int
    /// What the user originally asked for, so "is this a copy" is answerable.
    let draft: String

    var lower: String { text.lowercased() }
    var wordTokens: [Substring] { text.split(whereSeparator: \.isWhitespace) }
    var headings: [String] { PromptLinter.headings(lines) }
}

import Foundation

/// The fifteen structural checks, one function each.
///
/// They live apart from `PromptLinter` because the entry point is a report builder and these are
/// the rules: prompt doctrine changes here, the report format changes there, and neither edit
/// should put the other in conflict. Every check takes the same `LintContext` and returns an
/// `Issue?`, so adding a rule is one function plus one line in the registry.
///
/// The contract each check keeps: **test only what a string test can establish.** A false
/// positive is worse than a miss, because it teaches the operator to ignore the gate.
enum LinterChecks {

    typealias Issue = PromptLinter.Issue

    /// 1. Not wrapped in a code fence.
    static func fence(_ c: LintContext) -> Issue? {
        let lines = c.lines
        guard lines.count >= 3 else { return nil }
        let fenceLines = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        guard fenceLines.first == 0, fenceLines.last == lines.count - 1, fenceLines.count == 2 else { return nil }
        return PromptLinter.Issue(id: "fence", severity: .major, title: "Wrapped in a code fence",
                     detail: "The whole prompt sits inside ``` fences, so it cannot be pasted as instructions.",
                     fix: "Strip the outer fence.")
    }

    /// 2. No chat preamble.
    static func preamble(_ c: LintContext) -> Issue? {
        let lines = c.lines
        let target = c.target
        let first = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        // "Here is the CSV of orders, find the three regions…" is a chat message doing its job.
        // The chatter that has to be caught is the model addressing the user about the task.
        let openers = target == .chat
            ? ["sure", "certainly", "of course", "absolutely", "great", "okay", "ok,"]
            : ["sure", "certainly", "of course", "absolutely", "here's", "here is", "here are",
               "great", "okay", "ok,"]
        guard openers.contains(where: { first.hasPrefix($0) }) else { return nil }
        return PromptLinter.Issue(id: "preamble", severity: .major, title: "Starts with chat preamble",
                     detail: "First line: \u{201C}\(first.prefix(60))\u{201D}",
                     fix: "The output must start with the prompt itself, usually its title.")
    }

    /// 3. Required sections for the target.
    ///
    /// One entry per required section: a missing output contract and missing success
    /// criteria are separate, separately fixable defects.
    static func sections(_ c: LintContext) -> [(String, Issue?)] {
        let lines = c.lines
        let lower = c.lower
        let headings = c.headings
        let target = c.target
        let draft = c.draft
        return PromptLinter.requiredSections(for: c.target).map { name, alternatives in
            // A chat message is prose: it has no headings, so its required elements are matched
                // against the body. Demanding markdown structure of a chat message flagged every
                // well-formed one as broken.
                let byHeading = headings.contains { h in alternatives.contains(where: { h.contains($0) }) }
                // "Purpose: …" on its own line is a heading in everything but punctuation.
                let byLabel = PromptLinter.labels(lines)
                    .contains { label in alternatives.contains { label.hasPrefix($0) } }
                let byProse = target == .chat && alternatives.contains { lower.contains($0) }
                // A system prompt conventionally opens with its role — "You draft resignation
                // emails that…" is the purpose, and a ## Purpose heading above it would be
                // redundant. Accept the role statement in the opening lines.
                // "You are…" / "You draft…" / "Your job is…" in the opening lines states the role,
                // which is what the purpose section is for. A ## Purpose heading above it would be
                // redundant, and demanding one failed prompts that had already done the job.
                var opensWithRole = false
                if target == .systemPrompt, name == "purpose" {
                    let opening = lines
                        .prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
                        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    let roleOpeners = ["you are ", "you act as ", "you draft ", "you write ", "you review ",
                                       "you help ", "you convert ", "you classify ", "your role", "your job",
                                       "you serve as ", "you produce "]
                    opensWithRole = roleOpeners.contains { opening.hasPrefix($0) || opening.contains(". " + $0) }
                }
                // A section can be legitimately absent, and the writer is told to drop empty
                // ones. Without an escape the only two legal moves were "keep a heading that
                // carries no information" — which the same instruction forbids — or eat a
                // blocker. An explicit decline is the honest third option, and it is the pattern
                // the `inputs` anchor already uses.
                let declines = ["none", "not applicable", "n/a", "self-contained", "no background",
                                "nothing beyond", "no prior", "not needed", "no context"]
                let declined = PromptLinter.sectionBody(lines, matching: alternatives)
                    .lowercased()
                let explicitlyNone = declines.contains { declined.contains($0) }
                let found = byHeading || byLabel || byProse || opensWithRole || explicitlyNone
                guard !found else { return (name, nil) }
                let wanted = alternatives.joined(separator: " / ")
                let near = target == .chat ? "passage" : "heading"
                // Only the system-prompt `purpose` check accepts a role-opening line as the
                // section. Advertising that escape for every target told the repair model to do
                // something the check then rejected again.
                let fix: String
                if target == .chat {
                    fix = "Say it in the message."
                } else if target == .systemPrompt, name == "purpose" {
                    fix = "Add the \(name) section, or open with a line saying what you are."
                } else {
                    fix = "Add the \(name) section."
                }
                return (name, PromptLinter.Issue(id: "missing-\(name)", severity: .blocker,
                                                 title: "Missing \(name) section",
                                                 detail: "No \(near) matches \(wanted).",
                                                 fix: fix))
        }
    }

    /// 4. Success criteria must be checkable, not adjectives.
    static func criteria(_ c: LintContext) -> Issue? {
        let lines = c.lines
        let body = PromptLinter.sectionBody(lines, matching: ["success", "acceptance", "done", "criteria", "definition of done", "quality"])
        guard !body.isEmpty else { return nil }   // absence is already a blocker above
        // A human reviewer is a legitimate instrument. "A colleague who has not seen the page
        // can name which plan suits a two-person team" is checkable by exactly the person the
        // criterion names, and rejecting it pushed prompts toward fake automation.
        let measurable = ["pass", "return", "contain", "equal", "match", "at least", "no more than",
                          "within", "under ", "≤", "≥", "%", "command", "test", "field", "verify",
                          "check", "exit code", "grep", "diff", "count",
                          "can name", "can tell", "can state", "can point", "can identify",
                          "can answer", "a reader", "a colleague", "a reviewer", "someone who",
                          "without asking", "unprompted", "in one read", "two readers"]
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
        return PromptLinter.Issue(id: "vague-criteria", severity: .major, title: "Success criteria are not checkable",
                     detail: "The criteria section contains no threshold, command, field or verifiable verb.",
                     fix: "Rewrite each criterion as something a second person could run or read.")
    }

    /// 5. Filler and persona theatre.
    static func filler(_ c: LintContext) -> Issue? {
        let lower = c.lower
        let banned = ["world-class", "world class", "you are an expert", "as an ai", "cutting-edge",
                      "state-of-the-art", "best-in-class", "think outside the box", "unleash",
                      "you will be penalized", "this is critical", "it is crucial that you"]
        let hits = banned.filter { lower.contains($0) }
        guard !hits.isEmpty else { return nil }
        return PromptLinter.Issue(id: "filler", severity: .minor, title: "Filler phrases",
                     detail: hits.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "),
                     fix: "Delete them. They cost attention and steer nothing.")
    }

    /// 6. Shouting.
    static func shouting(_ c: LintContext) -> Issue? {
        let lines = c.lines
        let allow: Set<String> = ["API", "JSON", "CSV", "HTML", "CSS", "SQL", "HTTP", "HTTPS", "URL", "URLS",
                                  "CLI", "SDK", "PDF", "XML", "YAML", "TODO", "README", "LLM", "LLMS", "ID",
                                  "IDS", "OK", "GPT", "UI", "UX", "CI", "CD", "MCP", "NDA", "SLA", "ISO",
                                  "UTC", "GMT", "EUR", "USD", "AI", "RAG", "TDD", "PR", "PRS", "EU", "US",
                                  "UK", "GPU", "CPU", "RAM", "OS", "SQL", "JWT", "OATH", "ACL", "CRUD"]
        // Strip the places where caps are structural rather than emphatic: fenced blocks,
        // `code spans` and {{PLACEHOLDERS}}. A format placeholder like file.go:LINE is not
        // shouting, and neither is an identifier.
        var prose: [String] = []
        var insideFence = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { insideFence.toggle(); continue }
            if !insideFence { prose.append(line) }
        }
        let scannable = prose.joined(separator: "\n")
            .replacingOccurrences(of: "\\{\\{[^}]*\\}\\}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
        // Emphasis is a *run* of caps words: NEVER DO THIS. A single acronym per sentence is
        // domain vocabulary — LGTM, LINE, PATCH — and flagging it taught people to ignore this.
        let tokens = scannable.split(whereSeparator: { !($0.isLetter || $0 == "-") }).map(String.init)
        func isShouted(_ w: String) -> Bool {
            w.count >= 2 && w == w.uppercased() && w != w.lowercased() && !allow.contains(w)
        }
        var runs: [[String]] = []
        var current: [String] = []
        for w in tokens {
            if isShouted(w) { current.append(w) } else { if current.count >= 2 { runs.append(current) }; current = [] }
        }
        if current.count >= 2 { runs.append(current) }
        guard !runs.isEmpty else { return nil }
        let words = runs.flatMap { $0 }
        return PromptLinter.Issue(id: "shouting", severity: .minor, title: "ALL-CAPS emphasis",
                     detail: "\(runs.count) shouted phrase\(runs.count == 1 ? "" : "s"), e.g. \(words.prefix(3).joined(separator: " ")).",
                     fix: "Use plain emphasis, or say why the rule matters.")
    }

    /// 7. Placeholder hygiene.
    static func placeholders(_ c: LintContext) -> Issue? {
        let text = c.text
        let lower = c.lower
        let unansweredQuestions = c.unansweredQuestions
        let draft = c.draft
        // Distinct fields, not occurrences: {{LAST DAY}} used three times is one unfilled slot.
        // A resignation email legitimately needs six of them, and counting uses made a correct
        // prompt look like a draft.
        var fields = Set<String>()
        var rest = Substring(text)
        while let open = rest.range(of: "{{"), let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            fields.insert(rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces).uppercased())
            rest = rest[close.upperBound...]
        }
        let markers = ["[insert", "<insert", "[tbd", "xxx", "todo:"].filter { lower.contains($0) }.count
        let total = fields.count + markers
        // Density, not an absolute count. Seven placeholders in 864 words is a prompt that has
        // to be filled in; seven in a hundred words is a template with nothing around it. The
        // unanswered questions raise the floor, because each one legitimately needs a field.
        let words = text.split(whereSeparator: \.isWhitespace).count
        let ceiling = max(6, unansweredQuestions + 3, words / 100)
        guard total > ceiling else { return nil }
        return PromptLinter.Issue(id: "placeholders", severity: .major, title: "Too many placeholders",
                     detail: "\(total) unfilled slots. A prompt that is half placeholders is not a prompt yet.",
                     fix: "Fill the ones you know and move the rest into Assumptions with a default.")
    }

    /// 8. Unanswered questions must surface as assumptions, not vanish.
    static func assumptions(_ c: LintContext) -> Issue? {
        let lines = c.lines
        let lower = c.lower
        let headings = c.headings
        let target = c.target
        let unansweredQuestions = c.unansweredQuestions
        guard unansweredQuestions > 0 else { return nil }
        // A heading with nothing under it is the failure this check exists to catch, but so is
        // a section that restates the requirements. Requiring one recorded decision per
        // unanswered question is a property a string test can actually establish.
        let body = PromptLinter.sectionBody(lines, matching: ["assumption", "defaults", "decisions"])
        func bulletCount(_ block: String) -> Int {
            block.split(separator: "\n").filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("- ") || t.hasPrefix("* ") || t.first.map { $0.isNumber } == true
            }.count
        }
        // A prose target has no headings, so its recorded decisions appear as a labelled
        // clause — "Assumptions (already decided, do not ask):" — followed by its bullets.
        var proseEntries = 0
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var capturing = false
            var collected: [String] = []
            for line in lines {
                // A label is usually bolded — "**Assumptions:** …" — and requiring a bare word
                // failed the natural way of writing it. Strip leading emphasis before matching.
                let t = line.trimmingCharacters(in: .whitespaces)
                let bare = t.drop { "*_#>-\u{2022}".contains($0) }
                    .trimmingCharacters(in: .whitespaces)
                if bare.lowercased().hasPrefix("assumption") {
                    capturing = true
                    // A label ending in ":" may carry its first entry on the same line.
                    // A label that ends in ":" may carry its first entry on the same line, but
                    // a parenthetical after the colon is part of the label, not an entry.
                    let tail = bare.drop(while: { $0 != ":" }).dropFirst()
                        .trimmingCharacters(in: .whitespaces)
                    if !tail.isEmpty, tail.first != "(", tail.first != "\u{2014}", tail.first != "-" {
                        collected.append("- " + tail)
                    }
                    continue
                }
                if capturing {
                    if t.isEmpty || t.hasPrefix("- ") || t.hasPrefix("* ") || t.first?.isNumber == true {
                        if !t.isEmpty { collected.append(t) }
                    } else {
                        capturing = false
                    }
                }
            }
            proseEntries = bulletCount(collected.joined(separator: "\n"))
        }
        let entries = bulletCount(body) >= proseEntries ? bulletCount(body) : proseEntries
        // The heading establishes the semantics; the count establishes the volume. Requiring
        // the literal word "assume" inside an Assumptions section tested nothing.
        // Presence, not parity. One recorded decision can answer two questions, and a string
        // test cannot map questions to decisions — demanding one bullet per question failed
        // correct prompts. Whether the decisions actually cover the gaps is the critic's job.
        let hasSection = entries >= 1
        // Recorded inline instead of in a section: only unambiguous phrasing counts.
        // A chat message has no headings, so its recorded decisions appear as an inline clause:
        // "Assumptions: a neutral relationship; …". That is the correct form for prose.
        let hasInline = lower.contains("i assumed") || lower.contains("assuming ")
            || lower.contains("i chose ") || lower.contains("treating it as")
        guard !(hasSection || hasInline) else { return nil }
        return PromptLinter.Issue(id: "silent-defaults", severity: .major,
                     title: "\(unansweredQuestions) question\(unansweredQuestions == 1 ? "" : "s") left unanswered, no assumptions listed",
                     detail: "The prompt silently picks defaults the user never saw.",
                     fix: "Add an Assumptions section naming the default chosen for each open question.")
    }

    /// 9. Two different output formats declared.
    static func formats(_ c: LintContext) -> Issue? {
        let lower = c.lower
        let formats = ["json", "markdown", "csv", "yaml", "xml", "table", "bullet", "prose", "html"]
        // A format counts only when the sentence that names it does not also offer an
        // alternative. Testing the whole document meant one " or " anywhere silenced the check.
        func declares(_ f: String) -> Bool {
            for raw in lower.split(whereSeparator: { ".!?\n".contains($0) }) {
                // "Also emit a table" refers back to the previous sentence, so a bare mention
                // in a follow-on sentence still declares that format.
                let t = String(raw)
                // A bare preposition is not a declaration: "obvious in prose" and "grouped
                // in a table" are ordinary English. The sentence must also carry an output
                // verb, which is what makes it a contract rather than a remark.
                let outputVerb = ["output", "return", "respond", "reply", "deliver", "produce",
                                  "emit", "write", "answer", "format", "submit", "post",
                                  "comment", "report", "render"]
                guard outputVerb.contains(where: { t.contains($0) }) else { continue }
                let names = t.contains("output \(f)") || t.contains("as \(f)")
                    || t.contains("in \(f)") || t.contains("format: \(f)")
                    || t.contains("format is \(f)") || t.contains("return \(f)")
                    || t.contains("emit \(f)") || t.contains("emit a \(f)")
                    || t.contains("a \(f) file") || t.contains("\(f) document")
                    || t.contains("\(f) report") || t.contains("\(f) summary")
                guard names else { continue }
                if t.contains(" or ") || t.contains("either") { continue }
                return true
            }
            return false
        }
        // "The record in Markdown, and a JSON summary alongside it" is one contract with two
        // deliverables, not a contradiction. A conflict is two formats for the same output.
        //
        // Scoped to the declaring sentence. Testing the whole document meant an unrelated "as well
        // as the labels" anywhere silenced the check — the same document-wide matching this check
        // was rewritten to remove twelve lines above.
        let artefactWords = ["alongside", "along with", "as well as", "in addition",
                             "separately", "second file", "another file", "plus a"]
        func declaresSeparateArtefact(_ f: String) -> Bool {
            lower.split(whereSeparator: { ".!?\n".contains($0) }).contains { raw in
                let t = String(raw)
                guard t.contains(f) else { return false }
                return artefactWords.contains { t.contains($0) }
            }
        }
        let declared = formats.filter(declares)
        // A second format named in its own sentence, alongside a first, is a second deliverable.
        let separate = declared.filter(declaresSeparateArtefact)
        // `declared.count - separate.count` is the number of formats with no "alongside" marker.
        // One of them is the primary format; a second unmarked one is the conflict.
        guard declared.count - separate.count > 1 else { return nil }
        return PromptLinter.Issue(id: "format-conflict", severity: .major, title: "Conflicting output formats",
                     detail: "Declares \(declared.joined(separator: ", ")) without an either/or.",
                     fix: "Pick one format, or state which conditions choose between them.")
    }

    /// 10. Two different limits on the same *global* budget.
    /// 
    /// Restricted to units that describe the whole deliverable. "3 bullets" in one section and
    /// "5 bullets" in another is normal; "under 250 words" and "at least 600 words" is not.
    static func limits(_ c: LintContext) -> Issue? {
        let lines = c.lines
        let globalUnits = ["words", "characters", "pages", "lines"]
        let lowerBound = ["min", "minimum", "at least", "no fewer than", "fewer than", "over", "above", "≥", "from"]
        let upperBound = ["max", "maximum", "under", "at most", "no more than", "below", "limit", "≤", "up to"]
        let anyBound = lowerBound + upperBound + ["between", "roughly", "about", "around", "approx"]
        // Two parts of one deliverable may each carry a budget: "the summary at least 300
        // words; the appendix at most 200". The comment above claimed this was scoped to the
        // whole deliverable, but the loop scanned every line unscoped and failed correct prompts.
        let partWords = ["summary", "appendix", "section", "introduction", "conclusion",
                         "abstract", "executive", "chapter", "each", "per ", "for the ",
                         "body", "title", "caption", "description", "paragraph "]
        for unit in globalUnits {
            var lows: [Int] = [], highs: [Int] = []
            for line in lines {
                let lowerLine = line.lowercased()
                guard anyBound.contains(where: { lowerLine.contains($0) }) else { continue }
                if partWords.contains(where: { lowerLine.contains($0) }) { continue }
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
            return PromptLinter.Issue(id: "limit-conflict-\(unit)", severity: .major,
                         title: "Conflicting \(adjective) limits",
                         detail: "Both \(unique.map(String.init).joined(separator: " and ")) \(unit) appear as hard limits on the whole deliverable.",
                         fix: "Keep one number, or say which part of the deliverable each applies to.")
        }
        return nil
    }

    /// 11. No meta commentary.
    static func meta(_ c: LintContext) -> Issue? {
        let lower = c.lower
        // "Run the migration, then let me know if the row count changed" is an instruction to
        // the executor, not the model talking about the prompt.
        let meta = ["i will now", "i've written", "this prompt is designed", "hope this helps",
                    "here is the improved", "as an ai"]
        let hit = meta.first { lower.contains($0) }
        guard let hit else { return nil }
        return PromptLinter.Issue(id: "meta", severity: .major, title: "Model talks about the prompt",
                     detail: "\u{201C}\(hit)\u{201D}",
                     fix: "Strip commentary. The deliverable is the prompt.")
    }

    /// 12. Length envelope per target.
    static func length(_ c: LintContext) -> Issue? {
        let text = c.text
        let target = c.target
        let words = text.split(whereSeparator: \.isWhitespace).count
        let bounds = PromptLinter.lengthBounds(for: target)
        if words < bounds.min {
            let article = target == .agentTask ? "an" : "a"
            return PromptLinter.Issue(id: "too-short", severity: .major,
                         title: "Too thin for \(article) \(target.rawValue.lowercased())",
                         detail: "\(words) words; a usable one usually needs at least \(bounds.min).",
                         fix: "Add the missing sections rather than padding existing ones.")
        }
        if words > bounds.max {
            return PromptLinter.Issue(id: "too-long", severity: .minor, title: "Longer than it needs to be",
                         detail: "\(words) words; past ~\(bounds.max) compliance drops.",
                         fix: "Cut restatement and merge rules that share a reason.")
        }
        return nil
    }

    /// 13. Not a copy of the draft.
    static func copy(_ c: LintContext) -> Issue? {
        let text = c.text
        let draft = c.draft
        guard !draft.isEmpty else { return nil }
        let overlap = PromptLinter.jaccard(PromptLinter.contentWords(draft), PromptLinter.contentWords(text))
        guard overlap > 0.8 else { return nil }
        return PromptLinter.Issue(id: "copy", severity: .minor, title: "Mostly the original draft",
                     detail: "\(Int(overlap * 100))% of the draft's content words are unchanged.",
                     fix: "The value is in structure, criteria and constraints. Rewrite, don't reformat.")
    }

    /// 14. Unbounded effort words.
    static func effort(_ c: LintContext) -> Issue? {
        let lower = c.lower
        let vague = ["as much as possible", "as needed", "if necessary", "as appropriate", "be thorough",
                     "be comprehensive", "extensively", "in depth", "when relevant", "where applicable"]
        let hits = vague.filter { lower.contains($0) }
        guard !hits.isEmpty else { return nil }
        return PromptLinter.Issue(id: "unbounded", severity: .minor, title: "Unbounded effort",
                     detail: hits.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "),
                     fix: "Replace with a bound: how many, how long, until what condition.")
    }

    /// 15. Task executed instead of instructed.
    static func executed(_ c: LintContext) -> Issue? {
        let text = c.text
        let lines = c.lines
        let target = c.target
        let words = text.split(whereSeparator: \.isWhitespace).count
        // A chat message that performs the task in prose has no fence at all, so the fenced-content
        // test below could never see the one shape D16 takes on that target. Detect it directly:
        // a deliverable handed over in the first person.
        if target == .chat {
            let handover = ["here is the", "here's the", "here is a", "here's a", "i've written",
                            "i have written", "below is the", "below is a", "as requested, here",
                            "i wrote", "here you go", "hope this helps", "let me know if you"]
            let lower = c.lower
            if let hit = handover.first(where: { lower.contains($0) }) {
                return PromptLinter.Issue(id: "executed", severity: .major,
                             title: "Delivers the answer instead of the instruction",
                             detail: "Opens with \u{201C}\(hit)\u{201D}, so this is the result, not a prompt.",
                             fix: "Rewrite it as the request that would produce that result.")
            }
        }
        guard words > 250 else { return nil }
        // Measure how much of the output is fenced content. Two illustrative examples are what
        // the writer is told to produce; an output that is mostly one artefact is the failure.
        var fenced = 0
        var inside = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inside.toggle(); continue }
            if inside { fenced += line.split(whereSeparator: \.isWhitespace).count }
        }
        guard fenced > words / 2 else { return nil }
        return PromptLinter.Issue(id: "executed", severity: .minor, title: "Looks like the task was performed",
                     detail: "\(fenced) of \(words) words are fenced content.",
                     fix: "The deliverable is instructions. Keep only examples that teach a format.")
    }

}
