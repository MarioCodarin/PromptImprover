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

    /// Artefacts a bound or a format declaration can be scoped to. Shared by `limits` and
    /// `formats` so the two checks cannot disagree about what "the same deliverable" means.
    static let partTokens: Set<String> = ["summary", "appendix", "section", "introduction",
        "conclusion", "abstract", "executive", "chapter", "body", "title", "caption",
        "description", "file", "files", "guide", "readme", "email", "letter", "article",
        "memo", "changelog", "note", "post", "paragraph", "table"]

    var lower: String { text.lowercased() }
    var wordTokens: [Substring] { text.split(whereSeparator: \.isWhitespace) }
    var headings: [String] { PromptLinter.headings(lines) }
}

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
        // The opener has to be a whole word. A prefix test flagged "Surefire reports are flaky"
        // and "Greater than three retries is a bug" — both real first words in real prompts.
        func opens(_ first: String, _ o: String) -> Bool {
            guard first.hasPrefix(o) else { return false }
            guard let next = first.dropFirst(o.count).first else { return true }
            return !next.isLetter && !next.isNumber
        }
        guard openers.contains(where: { opens(first, $0) }) else { return nil }
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
        return PromptLinter.requiredSections(for: c.target).map { name, alternatives in
            // A chat message is prose: it has no headings, so its required elements are matched
                // against the body. Demanding markdown structure of a chat message flagged every
                // well-formed one as broken.
                let byHeading = headings.contains { h in alternatives.contains(where: { h.contains($0) }) }
                // "Purpose: …" on its own line is a heading in everything but punctuation. Matched
                // with `contains`, the way headings are: a prefix test made "Definition of done: …"
                // — a phrase this very table lists as a criteria keyword — unreachable, so a prompt
                // that had written its criteria was told it had none.
                let byLabel = PromptLinter.labels(lines)
                    .contains { label in alternatives.contains { label.contains($0) } }
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
                //
                // Matched on a line that *names the section and declines it*, not on the whole
                // document: "none" appears in ordinary prose constantly, and a document-wide test
                // would satisfy all five sections at once. `sectionBody` only ever returns a body
                // for a heading that already matched, so it alone could never rescue anything —
                // the decline escape was dead code until this line existed.
                let declines = ["none", "not applicable", "n/a", "self-contained", "no background",
                                "nothing beyond", "no prior", "not needed", "no context",
                                "nothing to add", "not required"]
                // Whole words only. `contains` made "none" match "nonetheless", so a document with
                // no context section that happened to contain the word "Nonetheless" satisfied the
                // context requirement — the escape accepted the opposite of a decline.
                func says(_ haystack: String, _ needle: String) -> Bool {
                    var from = haystack.startIndex
                    while let r = haystack.range(of: needle, range: from..<haystack.endIndex) {
                        let before = r.lowerBound == haystack.startIndex
                            ? nil : haystack[haystack.index(before: r.lowerBound)]
                        let after = r.upperBound == haystack.endIndex
                            ? nil : haystack[r.upperBound]
                        let cleanBefore = before.map { !$0.isLetter && !$0.isNumber } ?? true
                        let cleanAfter = after.map { !$0.isLetter && !$0.isNumber } ?? true
                        if cleanBefore && cleanAfter { return true }
                        from = r.upperBound
                    }
                    return false
                }
                let declineLine = lines.contains { line in
                    let t = line.lowercased()
                    guard alternatives.contains(where: { says(t, $0) }) else { return false }
                    return declines.contains { says(t, $0) }
                }
                let declined = PromptLinter.sectionBody(lines, matching: alternatives).lowercased()
                let explicitlyNone = declineLine || declines.contains { says(declined, $0) }
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
        //
        // The list also has to cover the "every X does Y" family, which is how criteria are
        // actually written in prose. It previously held only command-shaped vocabulary (grep, exit
        // code, a field), so "Every screen names the next action in its heading" — checkable by a
        // second person, which is the bar — was called unverifiable. Erring permissive is correct
        // here: this is a gate, and a false positive sends a good prompt back for repair.
        let measurable = ["pass", "return", "contain", "equal", "match", "at least", "no more than",
                          "within", "under ", "≤", "≥", "%", "command", "test", "field", "verify",
                          "check", "exit code", "grep", "diff", "count",
                          "can name", "can tell", "can state", "can point", "can identify",
                          "can answer", "a reader", "a colleague", "a reviewer", "someone who",
                          "without asking", "unprompted", "in one read", "two readers",
                          "every ", "each ", "names ", "renders", "fits", "traces", "reads as",
                          "same as", "unchanged", "identical", "shows ", "lists ", "states ",
                          "covers ", "nothing else", "no more"]
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
        // A quantifier is not a measurement. "Every screen names the next action in its heading"
        // is checkable; "Each section is well written and looks professional" is not, and the
        // "every "/"each " entries above accepted both. The difference is a quality adjective in
        // place of a property, so a clause whose only content is an evaluation of quality is
        // rejected even when it is quantified.
        let qualityWords = ["well written", "well-written", "professional", "high quality",
                            "high-quality", "excellent", "good", "great", "clear", "engaging",
                            "compelling", "polished", "beautiful", "clean", "readable", "nice",
                            "impressive", "solid", "strong", "appealing", "attractive", "fluent"]
        let clauses = body.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: ".;\n"))
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // The quantifiers and soft comparatives are exactly the entries that can appear in a
        // quality judgement, so they do not count as a hard signal here.
        let soft = ["every ", "each ", "names ", "shows ", "lists ", "states ", "covers ",
                    "fits", "traces", "reads as", "same as", "unchanged", "identical",
                    "nothing else", "no more"]
        let hard = measurable.filter { !soft.contains($0) }
        let onlyQuality = !clauses.isEmpty && clauses.allSatisfy { clause in
            qualityWords.contains { clause.contains($0) } && !hard.contains { clause.contains($0) }
        }
        // Only when *every* clause is a bare quality judgement does the section fail: a section
        // with one weak criterion and one measurable one still tells the executor what to aim at.
        guard !(hasNumber || (hasVerb && !onlyQuality)) else { return nil }
        return PromptLinter.Issue(id: "vague-criteria", severity: .major, title: "Success criteria are not checkable",
                     detail: "The criteria section contains no threshold, command, field or verifiable verb.",
                     fix: "Rewrite each criterion as something a second person could run or read.")
    }

    /// 5. Filler and persona theatre.
    static func filler(_ c: LintContext) -> Issue? {
        let lower = c.lower
        // A quoted phrase is the prompt talking *about* language, not using it: a support prompt
        // that forbids "As an AI language model I cannot…" was flagged for saying it.
        let stripped = strippingQuoted(lower)
        // Persona theatre and threats are never the subject matter.
        let always = ["you are an expert", "as an ai", "think outside the box", "unleash",
                      "you will be penalized", "this is critical", "it is crucial that you"]
        // These are product adjectives, and the product can be the subject: "Announce the
        // cutting-edge imaging sensor" is the deliverable's content, not padding around an
        // instruction. But a line of pure adjective theatre — "The tone is world-class,
        // cutting-edge and best-in-class" — is the padding this check exists for, and requiring
        // an explicit instruction cue on the same line let it through untouched.
        //
        // Two signals distinguish them, both about how the word is used. A stack of two or more
        // is theatre whatever else is on the line; a single one is theatre when it is predicated
        // of the output ("the tone is …") rather than attached to a noun being described.
        let adjectival = ["world-class", "world class", "cutting-edge", "state-of-the-art",
                          "best-in-class"]
        let copula = ["is ", "are ", "be ", "looks ", "seems ", "feels ", "sounds ", "reads "]
        var hits = always.filter { stripped.contains($0) }
        for line in stripped.split(separator: "\n") {
            let t = String(line)
            let found = adjectival.filter { t.contains($0) }
            guard !found.isEmpty else { continue }
            if found.count >= 2 { hits += found; continue }
            // A single term: theatre when predicated, subject matter when attributive.
            if copula.contains(where: { t.contains($0) }) { hits += found }
        }
        guard !hits.isEmpty else { return nil }
        return PromptLinter.Issue(id: "filler", severity: .minor, title: "Filler phrases",
                     detail: hits.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "),
                     fix: "Delete them. They cost attention and steer nothing.")
    }

    /// Text with quoted spans removed, so a phrase the prompt quotes in order to forbid it is not
    /// read as the prompt saying it. Both straight and typographic quotes.
    static func strippingQuoted(_ text: String) -> String {
        // Only short spans. A prompt that quotes a phrase in order to forbid it — `Never open with
        // "As an AI language model"` — is not using the phrase, so quoted text is removed before
        // matching. But a regex over any span between two quote marks also deletes everything
        // between two *inch marks*: `the card width is 12" and hope this helps you pick a 6"
        // gutter` had 60 characters of real content swallowed, and the handover phrase inside it
        // was hidden. A quoted phrase is short, so the span is bounded.
        func strip(_ s: String, _ open: Character, _ close: Character) -> String {
            var out = ""
            var i = s.startIndex
            while i < s.endIndex {
                // An inch mark is a quote character preceded by a digit: `12"`. It opens nothing,
                // so the span between two of them is not a quotation and must survive. This is
                // what a length bound could not distinguish.
                let inchMark = open == "\"" && i != s.startIndex
                    && s[s.index(before: i)].isNumber
                guard s[i] == open, !inchMark,
                      let end = s[s.index(after: i)...].firstIndex(of: close) else {
                    out.append(s[i])
                    i = s.index(after: i)
                    continue
                }
                out += " "
                i = s.index(after: end)
            }
            return out
        }
        return strip(strip(strip(text, "\"", "\""), "\u{201C}", "\u{201D}"), "\u{2018}", "\u{2019}")
    }

    /// 6. Shouting.
    static func shouting(_ c: LintContext) -> Issue? {
        let lines = c.lines
        let allow: Set<String> = ["API", "JSON", "CSV", "HTML", "CSS", "SQL", "HTTP", "HTTPS", "URL", "URLS",
                                  "CLI", "SDK", "PDF", "XML", "YAML", "TODO", "README", "LLM", "LLMS", "ID",
                                  "IDS", "OK", "GPT", "UI", "UX", "CI", "CD", "MCP", "NDA", "SLA", "ISO",
                                  "UTC", "GMT", "EUR", "USD", "AI", "RAG", "TDD", "PR", "PRS", "EU", "US",
                                  "UK", "GPU", "CPU", "RAM", "OS", "SQL", "JWT", "OATH", "ACL", "CRUD",
                                  // Domain vocabulary that is genuinely written in caps. Two of these
                                  // adjacent is a normal sentence, and the run rule then fired.
                                  "DNS", "TLS", "SSL", "SNI", "SAML", "SSO", "AWS", "GCP", "IAM", "KMS",
                                  "CMK", "UUID", "PK", "PCI", "DSS", "REST", "GRPC", "DB", "TTL", "MFA",
                                  "UAT", "QA", "BI", "ETL", "VPC", "ARN", "GUID", "SHA", "AES", "RSA",
                                  "HTTP2", "IP", "IPV4", "IPV6", "FQDN", "CDN", "WAF", "ORM", "SDLC",
                                  // Standards, compliance regimes and accessibility vocabulary. These
                                  // appear in pairs — "meets WCAG AA", "SOC 2", "GDPR DPA" — and two
                                  // adjacent caps tokens is exactly the run rule, so a correct
                                  // accessibility requirement was reported as shouting.
                                  "WCAG", "WAI", "ARIA", "AA", "AAA", "GDPR", "HIPAA", "SOX", "CCPA",
                                  "FERPA", "COPPA", "SOC", "DPA", "PII", "PHI", "SEO", "CRM", "ERP",
                                  "KPI", "OKR", "MVP", "POC", "ETA", "FYI", "ASAP", "NPS", "CSAT",
                                  "MRR", "ARR", "DAU", "MAU", "CTR", "ROAS", "B2B", "B2C", "SAAS",
                                  "PAAS", "IAAS", "PDF", "CSV", "PNG", "JPEG", "SVG", "GIF", "MP4"]
        // Strip the places where caps are structural rather than emphatic: fenced blocks,
        // `code spans`, {{PLACEHOLDERS}} and table headers. A format placeholder like file.go:LINE
        // is not shouting, and neither is an identifier.
        var prose: [String] = []
        var insideFence = false
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { insideFence.toggle(); continue }
            // A table *header* is a layout — "| SOURCE | TARGET |" is a column name, not emphasis.
            // The header is the row immediately above the `| --- |` delimiter, so only that row
            // is exempt. Skipping every `|` line hid real emphasis in the body of a table.
            let next = i + 1 < lines.count
                ? lines[i + 1].trimmingCharacters(in: .whitespaces) : ""
            let delimiter = next.replacingOccurrences(of: "|", with: "")
                .trimmingCharacters(in: .whitespaces)
            let isHeader = t.hasPrefix("|") && next.hasPrefix("|") && !delimiter.isEmpty
                && delimiter.allSatisfy { $0 == "-" || $0 == ":" || $0.isWhitespace }
            if !insideFence && !isHeader { prose.append(line) }
        }
        let scannable = prose.joined(separator: "\n")
            .replacingOccurrences(of: "\\{\\{[^}]*\\}\\}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
        // Emphasis is a *run* of caps words: NEVER DO THIS. A single acronym per sentence is
        // domain vocabulary — LGTM, LINE, PATCH — and flagging it taught people to ignore this.
        //
        // `_` stays in the alphabet so an identifier is one token: splitting it made
        // STRIPE_SECRET_KEY a three-word run and flagged a correct instruction as shouting.
        let tokens = scannable.split(whereSeparator: { !($0.isLetter || $0 == "-" || $0 == "_") }).map(String.init)
        func isShouted(_ w: String) -> Bool {
            // An identifier is one token because `_` stays in the alphabet, and an identifier is
            // not emphasis — but exempting every underscored token made an underscored *sentence*
            // invisible: DO_NOT_EVER_SHIP_THIS_WITHOUT_ASKING_ME_FIRST passed. A name has a few
            // short segments; a shouted instruction has many long ones.
            if w.contains("_") {
                let segments = w.split(separator: "_")
                let looksLikeAName = segments.count <= 6
                    && segments.allSatisfy { $0.count <= 12 }
                if looksLikeAName { return false }
                // A shouted sentence written with underscores is a run on its own: it has no
                // neighbours to pair with, because the underscores glue it into one token. Left
                // to the run rule it was invisible, which is how DO_NOT_EVER_SHIP_THIS passed.
                if segments.count >= 7 { return true }
            }
            return w.count >= 2 && w == w.uppercased() && w != w.lowercased() && !allow.contains(w)
        }
        var runs: [[String]] = []
        var current: [String] = []
        for w in tokens {
            if isShouted(w) { current.append(w) } else { if current.count >= 2 { runs.append(current) }; current = [] }
        }
        if current.count >= 2 { runs.append(current) }
        // An underscored caps sentence is one token and therefore its own run; `isShouted` already
        // decided it is not a name, so it does not need a neighbour to be counted.
        let soloRuns = tokens.filter { isShouted($0) && $0.contains("_") && $0.split(separator: "_").count >= 7 }
        for w in soloRuns where !runs.contains([w]) { runs.append([w]) }
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
        //
        // The absolute floor is 8 — a letter template addresses a name, an address, a contact, a
        // start date, an end date, a fee and an uplift, and every one is required by the
        // deliverable. But a floor alone let eight fields through in 43 words, which is a skeleton.
        // Both tests have to hold: eight is not too many only when there is prose around them.
        let words = text.split(whereSeparator: \.isWhitespace).count
        let ceiling = max(8, unansweredQuestions + 3, words / 100)
        // One field per twelve words of surrounding instruction, at the point where the absolute
        // floor applies. 7 fields in 110 words (15:1) passes; 8 in 43 words (5:1) does not.
        let sparse = words < total * 12
        guard total > ceiling || (total >= 8 && sparse) else { return nil }
        return PromptLinter.Issue(id: "placeholders", severity: .major, title: "Too many placeholders",
                     detail: "\(total) unfilled slots. A prompt that is half placeholders is not a prompt yet.",
                     fix: "Fill the ones you know and move the rest into Assumptions with a default.")
    }

    /// 8. Unanswered questions must surface as assumptions, not vanish.
    static func assumptions(_ c: LintContext) -> Issue? {
        let lines = c.lines
        let unansweredQuestions = c.unansweredQuestions
        guard unansweredQuestions > 0 else { return nil }
        // A heading with nothing under it is the failure this check exists to catch, but so is
        // a section that restates the requirements. Requiring one recorded decision per
        // unanswered question is a property a string test can actually establish.
        let body = PromptLinter.sectionBody(lines, matching: ["assumption", "defaults", "decisions"])
        func bulletCount(_ block: String) -> Int {
            block.split(separator: "\n").filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("\u{2022} ")
                    || t.first.map { $0.isNumber } == true
            }.count
        }
        // A prose target has no headings, so its recorded decisions appear as a labelled
        // clause — "Assumptions (already decided, do not ask):" — followed by its bullets.
        var proseEntries = 0
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var capturing = false
            var collected: [String] = []
            // A label is usually bolded — "**Assumptions:** …" — and requiring a bare word failed
            // the natural way of writing it. The heading path accepts "assumption", "defaults" and
            // "decisions"; this path accepted only "assumption", so a chat message that recorded
            // its decisions under "Defaults:" was told it had recorded none.
            func labelled(_ raw: String) -> String? {
                let bare = raw.trimmingCharacters(in: .whitespaces)
                    .drop { "*_#>-\u{2022}".contains($0) }
                    .trimmingCharacters(in: .whitespaces)
                guard ["assumption", "default", "decision"]
                    .contains(where: { bare.lowercased().hasPrefix($0) }) else { return nil }
                return String(bare)
            }
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                // A chat message is one paragraph, so its labelled clause sits mid-line, after a
                // sentence terminator: "… no sign-off. Defaults: two weeks, no impact claimed."
                let starts = [t] + t.components(separatedBy: ". ")
                    .dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
                if let bare = starts.compactMap(labelled).first {
                    capturing = true
                    // A label ending in ":" may carry its first entry on the same line, but a
                    // parenthetical after the colon is part of the label, not an entry.
                    let tail = bare.drop(while: { $0 != ":" }).dropFirst()
                        .trimmingCharacters(in: .whitespaces)
                    // An entry has to record a decision. "Decisions: whatever you think is best"
                    // records nothing — it hands the choice back — and counting it as one entry
                    // satisfied the check while the prompt still silently picked a default.
                    let defers = ["whatever", "you think", "your call", "up to you", "you decide",
                                  "anything", "tbd", "not sure", "as you see fit", "any of"]
                    let records = !defers.contains { tail.lowercased().contains($0) }
                    if !tail.isEmpty, tail.first != "(", tail.first != "\u{2014}",
                       tail.first != "-", records {
                        collected.append("- " + tail)
                    }
                    continue
                }
                if capturing {
                    if t.isEmpty || t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("\u{2022} ")
                        || t.first?.isNumber == true {
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
        // Recorded inline instead of in a section.
        //
        // The previous list was first-person narration only — "I assumed", "I chose" — and a
        // prompt is written in the imperative, so it could never match. A live chat run that
        // recorded every gap it was asked about ("No product details, brand, testimonials or
        // pricing were supplied: use a neutral placeholder brand, {{BRAND}}" … "Invent no pricing")
        // was failed for not recording them, because it said so without narrating itself.
        //
        // What counts is that the gap is named and a default is stated, in either voice.
        // Only phrasing that names a *choice*. A gap-handling instruction — "quote no metric you
        // were not given", "invent no pricing", "mark it as a placeholder" — is an output
        // constraint: it says what not to do when a value is missing, not which value was picked.
        // Counting those let a prompt that had decided nothing about the open questions pass,
        // which is the exact failure this check exists to catch.
        let chose = ["assume", "assumed", "assuming", "default to", "by default",
                     "treat it as", "treat the", "treating it as", "i chose", "i picked", "we chose"]
        let proseOnly = lines.filter { PromptLinter.headingTitle(of: $0) == nil }
            .joined(separator: "\n").lowercased()
        // "never assume a brand name" records nothing — it is the gap-handling instruction this
        // list is supposed to exclude, written with the verb the list keys on. A negation in front
        // of the phrase means no decision was made.
        let negations = ["never ", "not ", "don't ", "do not ", "no ", "without ", "avoid "]
        func records(_ phrase: String) -> Bool {
            var from = proseOnly.startIndex
            while let r = proseOnly.range(of: phrase, range: from..<proseOnly.endIndex) {
                let head = String(proseOnly[proseOnly.startIndex..<r.lowerBound].suffix(12))
                if !negations.contains(where: { head.hasSuffix($0) }) { return true }
                from = r.upperBound
            }
            return false
        }
        let hasInline = chose.contains { records($0) }
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
        func declares(_ f: String) -> String? {
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
                // "in \(f)" counts only as the object of an output verb. A bare preposition is
                // ordinary English, but "output the log in CSV" is a contract — and dropping the
                // pattern entirely, as an earlier version did, meant the plainest way of naming
                // two output formats declared neither.
                let inObject = t.range(
                    of: "\\b(output|outputs|return|returns|respond|reply|deliver|produce|emit|write|"
                        + "format|submit|render|send|give)\\b[^.]{0,24}?\\bin \(f)\\b",
                    options: .regularExpression) != nil
                let names = inObject
                    || t.contains("output \(f)") || t.contains("as \(f)")
                    || t.contains("format: \(f)")
                    || t.contains("format is \(f)") || t.contains("return \(f)")
                    || t.contains("emit \(f)") || t.contains("emit a \(f)")
                    || t.contains("a \(f) file") || t.contains("\(f) document")
                    || t.contains("\(f) report") || t.contains("\(f) summary")
                guard names else { continue }
                // The sanctioned resolution is "state which conditions choose between them", and
                // the issue's own fix text says so. Recognising only "or"/"either" meant a prompt
                // that had done exactly that was still failed for it.
                //
                // A conditional excuses a format only when it actually chooses between them.
                // "Return JSON if you can, and also as CSV" is not a choice, and treating any
                // "if " as one made the commonest real conflict invisible.
                let assertsBoth = ["and also", "both ", "as well as", "plus ", "and csv",
                                   "and json", "and markdown", "and yaml", "and html"]
                let conditional = [" or ", "either", "if ", "when ", "on request", "asks for",
                                   "asked for", "otherwise", "depending on"]
                if conditional.contains(where: { t.contains($0) }),
                   !assertsBoth.contains(where: { t.contains($0) }) { continue }
                // The artefact this format belongs to, scoped exactly as `limits` scopes a word
                // bound: the nearest one named before it in the same sentence. "Return the summary
                // as JSON, and the appendix as a Markdown file" is two contracts for two
                // deliverables; without this it read as one contract with two formats, which is
                // the false positive `limits` was narrowed to avoid in the same release.
                return nearestPart(in: t, before: t.range(of: f)?.lowerBound)
            }
            return nil
        }
        /// The nearest artefact named before `cut` in one sentence, or "" for the whole
        /// deliverable. Shared with `limits` so both checks scope a declaration the same way.
        func nearestPart(in text: String, before cut: String.Index?) -> String {
            guard let cut else { return "" }
            let words = text[text.startIndex..<cut]
                .split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() }
            for w in words.reversed() where LintContext.partTokens.contains(w) { return w }
            return ""
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
        // Each declaration carries the artefact it governs and whether it was marked as a second
        // deliverable. A conflict needs two formats on the *same* artefact, neither marked separate.
        var pairs: [(format: String, part: String)] = []
        for f in formats {
            guard let part = declares(f), !declaresSeparateArtefact(f) else { continue }
            pairs.append((f, part))
        }
        let declared = formats.filter { declares($0) != nil }
        var conflict = false
        for (i, a) in pairs.enumerated() {
            for b in pairs[(i + 1)...] where a.part == b.part { conflict = true }
        }
        guard conflict else { return nil }
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
        // Two parts of one deliverable may each carry a budget: "the summary at least 300 words;
        // the appendix at most 200". A bound is therefore scoped to the artefact named nearest
        // before it, and only bounds on the *same* artefact (or on the whole deliverable) can
        // contradict each other.
        //
        // Matching the line instead of the number was wrong in both directions. It skipped every
        // line mentioning a part at all, so "the email under 250 words … the email at least 600"
        // — the canonical contradiction — passed; and `contains` made "file" match "profile".
        let partTokens = LintContext.partTokens
        let partPhrases = ["release note", "cover letter", "press release"]
        // Pronouns that stand in for the artefact named in the previous bound.
        let pronouns: Set<String> = ["it", "its", "they", "them", "their", "this", "these", "those"]

        struct Bound { let value: Int; let isFloor: Bool; let part: String }
        for unit in globalUnits {
            var bounds: [Bound] = []
            for line in lines {
                let lowerLine = line.lowercased()
                guard anyBound.contains(where: { lowerLine.contains($0) }) else { continue }
                // "1,000 words" is one thousand, not zero.
                let cleaned = lowerLine.replacingOccurrences(of: ",", with: "")
                let tokens = cleaned.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
                for (i, w) in tokens.enumerated() where w == unit || w == String(unit.dropLast()) {
                    guard i > 0, let n = Int(tokens[i - 1]) else { continue }
                    // The artefact this bound belongs to: the nearest one named just before it.
                    var part = ""
                    for j in stride(from: i - 2, through: max(0, i - 7), by: -1) where j >= 0 {
                        if j + 1 < i, partPhrases.contains(tokens[j] + " " + tokens[j + 1]) {
                            part = tokens[j] + " " + tokens[j + 1]
                            break
                        }
                        if partTokens.contains(tokens[j]) { part = tokens[j]; break }
                    }
                    // "The email must be at least 600 words. Keep it under 250 words." — the
                    // second bound names no artefact, because the sentence uses a pronoun for the
                    // one just named. Without this, the two bounds landed in different groups and
                    // the canonical contradiction was never seen. A pronoun inherits the nearest
                    // preceding part; anything else stays scoped to the whole deliverable.
                    if part.isEmpty,
                       tokens[max(0, i - 5)..<i].contains(where: { pronouns.contains($0) }),
                       let last = bounds.last?.part, !last.isEmpty {
                        part = last
                    }
                    // Classify by the bound word nearest the number, not by the unit alone:
                    // "at least 250 words … at most 600 words" is a range, not a conflict.
                    let context = tokens[max(0, i - 4)..<i].joined(separator: " ")
                    if lowerBound.contains(where: { context.contains($0) }) {
                        bounds.append(Bound(value: n, isFloor: true, part: part))
                    } else if upperBound.contains(where: { context.contains($0) }) {
                        bounds.append(Bound(value: n, isFloor: false, part: part))
                    }
                }
            }
            // Only an unsatisfiable pair is a conflict: a floor above a ceiling, on the same
            // artefact. Two ceilings ("under 1,000 words" and "at most 1,400") or two floors are
            // redundant, and the tighter one simply wins — flagging those punished care.
            for part in Set(bounds.map(\.part)) {
                let group = bounds.filter { $0.part == part }
                let lo = group.filter(\.isFloor).map(\.value).max()
                let hi = group.filter { !$0.isFloor }.map(\.value).min()
                guard let lo, let hi, lo > hi else { continue }
                let unique = Array(Set([lo, hi])).sorted()
                let adjective = ["words": "word", "characters": "character",
                                 "pages": "page", "lines": "line"][unit] ?? unit
                let scope = part.isEmpty ? "the whole deliverable" : "the \(part)"
                return PromptLinter.Issue(id: "limit-conflict-\(unit)", severity: .major,
                             title: "Conflicting \(adjective) limits",
                             detail: "Both \(unique.map(String.init).joined(separator: " and ")) \(unit) appear as hard limits on \(scope).",
                             fix: "Keep one number, or say which part of the deliverable each applies to.")
            }
        }
        return nil
    }

    /// 11. No meta commentary.
    static func meta(_ c: LintContext) -> Issue? {
        // "Run the migration, then let me know if the row count changed" is an instruction to
        // the executor, not the model talking about the prompt.
        //
        // "i've written" was removed: "I've written a first draft below, rewrite it in a plainer
        // voice" is the canonical chat prompt, and it fired here *and* in `executed`. Quoted spans
        // are stripped first, so a prompt that forbids "As an AI language model I cannot…" is not
        // flagged for quoting it.
        let stripped = strippingQuoted(c.lower)
        let meta = ["i will now", "this prompt is designed", "hope this helps",
                    "here is the improved", "as an ai"]
        let hit = meta.first { stripped.contains($0) }
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
        // The ceiling is about restatement, so pasted source does not count toward it — but only
        // when the message is *mostly* pasted source. Subtracting the fence unconditionally let a
        // 941-word message with a 464-word fence pass a 500-word ceiling, which is exactly the
        // restatement the check exists to catch, and it defeated `executed`'s own fence test at
        // the same time.
        let fenced = fencedWordCount(c.lines)
        let proseWords = fenced > words / 2 ? words - fenced : words
        if proseWords > bounds.max {
            return PromptLinter.Issue(id: "too-long", severity: .minor, title: "Longer than it needs to be",
                         detail: "\(proseWords) words of instructions; past ~\(bounds.max) compliance drops.",
                         fix: "Cut restatement and merge rules that share a reason.")
        }
        return nil
    }

    /// Words inside fenced blocks, which are quoted material rather than instruction.
    static func fencedWordCount(_ lines: [String]) -> Int {
        var fenced = 0
        for (i, line) in lines.enumerated() where fencedLineFlags(lines)[i] {
            fenced += line.split(whereSeparator: \.isWhitespace).count
        }
        return fenced
    }

    /// Which lines sit inside a fenced block. The fence markers themselves are excluded.
    static func fencedLineFlags(_ lines: [String]) -> [Bool] {
        var flags: [Bool] = []
        var inside = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inside.toggle()
                flags.append(false)
                continue
            }
            flags.append(inside)
        }
        return flags
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
        // Judged per clause, because "as needed" can be the bound rather than the absence of one:
        // "scale the pool as needed between four and sixteen workers" is bounded by the same
        // sentence. A clause that carries a number or a range is not unbounded.
        // Split on commas too. The bound has to be attached to the vague phrase, and a whole
        // sentence can carry an unrelated number: "read the surrounding modules as much as
        // possible, and keep the diff under 300 lines" bounded the diff, not the reading, yet the
        // sentence-level test exempted the phrase entirely.
        let clauses = lower.split(whereSeparator: { ".!?;,\n".contains($0) }).map(String.init)
        var hits: [String] = []
        for clause in clauses {
            let found = vague.filter { clause.contains($0) }
            guard !found.isEmpty else { continue }
            if clause.contains(where: \.isNumber) || clause.contains("between") { continue }
            hits += found
        }
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
        // a deliverable handed over in the *opening*.
        //
        // The opening, not anywhere in the message. Half of the previous list ("here is the",
        // "below is the", "i've written") is how a person introduces their *input*, so a textbook
        // chat request — "Here is the error our checkout page throws on Safari: … fix the cause" —
        // was reported as delivering the answer instead of the instruction.
        if target == .chat {
            let handover = ["here's your", "here is your", "here's the answer", "here is the answer",
                            "here's the finished", "here is the finished", "here's the reply",
                            "here is the reply", "here's the rewritten", "here is the rewritten",
                            "i've written the", "i wrote the", "here you go", "hope this helps"]
            // The whole message, not its first line. Restricting the test to line one let a
            // delivered reply through whenever it carried a title above it — "Rewritten reply,
            // under 100 words:" followed by the reply itself passed the gate outright.
            //
            // What separates a delivery from a request that quotes an artefact is not position,
            // it is whether the message asks for anything. "Here is the error our checkout throws:
            // … fix the cause" is a request; "Here is the reply you asked for: Dear customer…" is
            // not. So a request verb anywhere in the message exempts it.
            // Word-bounded, and imperative. "reviewed your case" is not a request to review, and
            // a substring test on "review" made every delivered reply that mentioned a review
            // look like a request for one.
            // Not "rewritten": that is the handover ("here's your rewritten reply"), not a request.
            // "write" was missing, and it is the commonest request verb there is. A chat prompt
            // that opened "Write a summary of the attached report…" and forbade a handover phrase
            // ("never open with \"Here's your summary\"") was graded as the handover itself — a
            // major, so a clean prompt bought a repair call to fix a defect it did not have.
            //
            // It is listed with its objects rather than bare, because a bare "write" also matches
            // "write back if you need anything", which is a closing pleasantry in a delivered reply.
            // "Write a summary" is a directive; "write back" is not.
            //
            // "please" is matched word-bounded like the rest: the trailing space made it match only
            // before punctuation, so "please rewrite this" exempted nothing.
            let requests = ["write a", "write an", "write the", "write me", "write up", "write one",
                            "rewrite", "fix", "summarise", "summarize", "tell me",
                            "explain", "convert", "turn it", "turn this", "make it", "give me",
                            "produce", "draft", "describe", "improve", "shorten", "expand",
                            "translate", "correct", "help me", "can you", "could you", "i need",
                            "i want", "please"]
            let lowered = text.lowercased()
            func word(_ needle: String) -> Bool {
                var from = lowered.startIndex
                while let r = lowered.range(of: needle, range: from..<lowered.endIndex) {
                    let before = r.lowerBound == lowered.startIndex
                        ? nil : lowered[lowered.index(before: r.lowerBound)]
                    let after = r.upperBound == lowered.endIndex ? nil : lowered[r.upperBound]
                    if (before.map { !$0.isLetter } ?? true), (after.map { !$0.isLetter } ?? true) {
                        return true
                    }
                    from = r.upperBound
                }
                return false
            }
            let isRequest = requests.contains { word($0) }
            let inFence = fencedLineFlags(lines)
            var hit: String?
            for (i, line) in lines.enumerated() where !inFence[i] {
                let t = line.trimmingCharacters(in: .whitespaces).lowercased()
                if let h = handover.first(where: { t.contains($0) }) { hit = h; break }
            }
            if let hit, !isRequest {
                return PromptLinter.Issue(id: "executed", severity: .major,
                             title: "Delivers the answer instead of the instruction",
                             detail: "Contains \u{201C}\(hit)\u{201D} and asks for nothing, so this is the result, not a prompt.",
                             fix: "Rewrite it as the request that would produce that result.")
            }
        }
        guard words > 250 else { return nil }
        // Measure how much of the output is fenced content. Two illustrative examples are what
        // the writer is told to produce; an output that is mostly one artefact is the failure.
        let fenced = fencedWordCount(lines)
        guard fenced > words / 2 else { return nil }
        return PromptLinter.Issue(id: "executed", severity: .minor, title: "Looks like the task was performed",
                     detail: "\(fenced) of \(words) words are fenced content.",
                     fix: "The deliverable is instructions. Keep only examples that teach a format.")
    }

}
