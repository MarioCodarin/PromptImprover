import Foundation

/// Turns what a model returned into the pipeline's own types.
///
/// Kept apart from `MetaPrompts` on purpose: prompt text changes when the doctrine changes,
/// parsing changes when a model misbehaves, and the two have no reason to be edited together.
public enum ResponseParsing {

    // MARK: - Output hygiene

    /// Everything a streamed reply needs before it can be judged: reasoning blocks removed, and a
    /// wrapper fence stripped. Idempotent, so a repair that re-emits clean text is unaffected.
    public static func finalize(_ raw: String) -> String { unfence(stripThinking(raw)) }

    /// Removes <think>…</think> blocks some reasoning models emit inline: an unclosed one mid-stream, and an
    /// orphan </think> (chat templates that put the opening tag in the prompt, so only the closing tag comes back).
    public static func stripThinking(_ s: String) -> String {
        var out = s
        if let close = out.range(of: "</think>"),
           out.range(of: "<think>", range: out.startIndex..<close.lowerBound) == nil {
            out.removeSubrange(out.startIndex..<close.upperBound)
        }
        while let start = out.range(of: "<think>") {
            if let end = out.range(of: "</think>", range: start.upperBound..<out.endIndex) {
                out.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                out.removeSubrange(start.lowerBound..<out.endIndex)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes one code fence wrapping the *whole* output. Only when the first and last lines are the only
    /// fence lines, so output that starts and ends with separate code blocks is left alone.
    public static func unfence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = t.components(separatedBy: "\n")
        let fences = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        guard lines.count >= 3, fences == [0, lines.count - 1],
              lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```" else { return t }
        return lines[1..<(lines.count - 1)].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tolerant JSON

    /// Pulls the first *parseable* JSON object out of a model reply.
    ///
    /// Models wrap JSON in prose, fences, or emit a second object afterwards; a brace counter that
    /// respects string literals handles all three. It also has to survive a `{` that is not JSON at
    /// all, which is why this walks candidate starts instead of committing to the first one: a
    /// brief mentioning `{{name}}` or an example object before the answer used to consume the one
    /// attempt, and every consumer then degraded silently — `parseDiagnosis` returned an all-default
    /// diagnosis, so the writer ran blind with no findings and no questions.
    /// `rank` picks between several parseable objects; the highest score wins, first on a tie.
    ///
    /// Models routinely open with the schema before the content — "your reply must be a JSON object
    /// with this shape: `{"brief": "", "findings": [], "questions": []}`" — and that example is
    /// *valid JSON*, so it closes at depth 0 and was returned as the answer. The real diagnosis
    /// after it was never read: `parseDiagnosis` returned an empty brief with risk "low" and no
    /// findings, and `parseCritique` returned `verdict: ship` with no issues, so a prompt the critic
    /// never scored was treated as passing.
    ///
    /// Returning the first parseable object is the bug. Skipping spans that "look empty" is the
    /// wrong fix, because a legitimate `{"verdict": "ship", "issues": []}` is empty-looking too.
    /// So every span is parsed and the caller's rank decides which one is the answer.
    public static func jsonObject(from raw: String,
                           rank: (([String: Any]) -> Int)? = nil) -> [String: Any]? {
        let text = unfence(stripThinking(raw))
        var best: ([String: Any], Int)?
        func consider(_ obj: [String: Any]) {
            let score = rank?(obj) ?? 0
            if best == nil || score > best!.1 { best = (obj, score) }
        }
        // One scan. A candidate object is a span that opens at brace depth 0 and closes back at 0,
        // so a `{` nested inside an unterminated one is never offered as a start: falling back to
        // an inner object would return a partial parse that looks like a valid answer, which is
        // worse than returning nothing.
        //
        // The depth is clamped at zero. Prose is allowed to contain a stray brace — "wrap it in {
        // then paste the answer", a `{` in an example, a `}` from a truncated quote — and an
        // unclamped counter latched: one unmatched `}` drove the depth to -1, after which no real
        // opener was ever offered, and one unmatched `{` left the depth at 1 so the answer closed
        // to 1 and never to 0. Both silently produced an all-default diagnosis.
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{":
                    if depth == 0 { start = i }
                    depth += 1
                case "}":
                    // A closer with no opener is prose, not structure.
                    guard depth > 0 else { i = text.index(after: i); continue }
                    depth -= 1
                    if depth == 0, let s = start {
                        if let obj = parseObject(text[s...i]) {
                            if rank == nil { return obj }
                            consider(obj)
                        }
                        // Keep scanning: an example of the schema may come before the answer.
                        start = nil
                    }
                default: break
                }
            }
            i = text.index(after: i)
        }
        // An opener that never closed is deliberately not retried from the next brace. A `{` in
        // prose followed by a complete answer and a genuinely truncated object have the same
        // shape — `wrap it in { then paste {"a":1}` and `{"a":1,"b":{"c":2}` both leave the depth
        // at 1 — so retrying would return `{"c":2}` for the truncated object, and a partial parse
        // that looks like a valid answer is worse than none. The callers already treat nil as "the
        // model said nothing" and fall back to the linter's own findings.
        return best?.0
    }

    /// Parses one brace-balanced slice, tolerating a trailing comma before `}` or `]`.
    ///
    /// A trailing comma is the most common defect in model JSON. Rejecting it was spec-correct and
    /// useless: the parse failed, the caller got nil, and the run carried on with no defect list
    /// and no signal. Stripped here in the scanner rather than with a regex, because `,(\s*[}\]])`
    /// would corrupt any string literal containing `,}`.
    private static func parseObject(_ slice: Substring) -> [String: Any]? {
        if let obj = (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any] {
            return obj
        }
        let repaired = droppingTrailingCommas(slice)
        guard repaired != slice else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(repaired.utf8))) as? [String: Any]
    }

    /// Removes a comma that only precedes `}` or `]`, leaving every string literal untouched.
    ///
    /// One pass over characters, tracking string state, with a lookahead to the next structural
    /// character. Doing this with a regex would corrupt a value that legitimately contains `,}`.
    private static func droppingTrailingCommas(_ slice: Substring) -> String {
        let chars = Array(slice)
        var out = ""
        out.reserveCapacity(chars.count)
        var inString = false
        var escaped = false
        for (i, c) in chars.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                out.append(c)
                continue
            }
            if c == "\"" { inString = true; out.append(c); continue }
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { continue }
            }
            out.append(c)
        }
        return out
    }

    public static func parseDiagnosis(_ raw: String) -> Diagnosis {
        var d = Diagnosis()
        // An example of the schema is not a diagnosis. `{"brief": "", "findings": [], "questions":
        // []}` scores 0 here and loses to the real answer that follows it; if no span carries any
        // content, the scan returns the empty one and this degrades exactly as it did before.
        guard let obj = jsonObject(from: raw, rank: { o in
            let brief = (o["brief"] as? String) ?? ""
            return (brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 100)
                + (o["findings"] as? [Any] ?? []).count
                + (o["scores"] as? [String: Any] ?? [:]).count
                + (o["questions"] as? [Any] ?? []).count
        }) else { return d }

        d.brief = (obj["brief"] as? String) ?? ""
        d.taskType = (obj["task_type"] as? String) ?? ""
        d.risk = (obj["risk"] as? String) ?? "low"
        d.assumptions = (obj["assumptions"] as? [Any] ?? []).compactMap { $0 as? String }

        d.findings = (obj["findings"] as? [Any] ?? []).compactMap { item in
            guard let f = item as? [String: Any],
                  let code = f["code"] as? String else { return nil }
            // The taxonomy is keyed on upper-case codes. Looking it up with the model's raw text
            // meant `{"code":"d07"}` was labelled minor in the list while `Finding.title` reported
            // it as a blocker — one finding, two severities.
            //
            // An *omitted* severity also falls through to the taxonomy. It used to default to
            // "minor" outright, so the code — which is the authoritative field, and is what the
            // defect list is keyed on — was never consulted at all.
            let upper = code.uppercased()
            let declared = (f["severity"] as? String)
                .flatMap { Defect.Severity(rawValue: $0.lowercased()) }
            let sev = declared ?? Defect.severity(for: upper)
            return Finding(code: upper,
                           severity: sev,
                           quote: (f["quote"] as? String) ?? "",
                           fix: (f["fix"] as? String) ?? "")
        }

        d.scores = parseScores(obj["scores"])

        d.questions = (obj["questions"] as? [Any] ?? []).compactMap { item in
            guard let q = item as? [String: Any],
                  let text = (q["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let options = (q["options"] as? [Any] ?? []).compactMap { opt -> String? in
                if let s = opt as? String { return s }
                if let n = opt as? NSNumber { return n.stringValue }
                return nil
            }
            return ClarifyingQuestion(question: text,
                                      why: q["why"] as? String ?? "",
                                      options: options,
                                      default: q["default"] as? String ?? "")
        }
        d.questions = Array(d.questions.prefix(4))
        return d
    }

    public static func parseCritique(_ raw: String) -> Critique? {
        // A schema example (`{"verdict": "ship", "issues": []}`) is legal JSON and used to be
        // returned as the verdict, so a prompt the critic never scored was read as passing. The
        // real critique carries issues, scores or a summary and outranks it.
        guard let obj = jsonObject(from: raw, rank: { o in
            let verdict = (o["verdict"] as? String)?.lowercased() ?? ""
            let legal = verdict == "ship" || verdict == "repair"
            let summary = (o["summary"] as? String) ?? ""
            return (legal ? 100 : 0)
                + (o["issues"] as? [Any] ?? []).count
                + (o["scores"] as? [String: Any] ?? [:]).count
                + (summary.isEmpty ? 0 : 1)
        }) else { return nil }
        var c = Critique()
        c.verdict = (obj["verdict"] as? String)?.lowercased() == "repair" ? "repair" : "ship"
        c.summary = (obj["summary"] as? String) ?? ""
        c.scores = parseScores(obj["scores"])
        c.strengths = (obj["strengths"] as? [Any] ?? []).compactMap { $0 as? String }

        c.issues = (obj["issues"] as? [Any] ?? []).compactMap { item in
            guard let i = item as? [String: Any],
                  let axis = i["axis"] as? String else { return nil }
            let sev = Defect.Severity(rawValue: (i["severity"] as? String ?? "minor").lowercased()) ?? .minor
            return CritiqueIssue(axis: axis.lowercased(),
                                 severity: sev,
                                 quote: (i["quote"] as? String) ?? "",
                                 problem: (i["problem"] as? String) ?? "",
                                 fix: (i["fix"] as? String) ?? "")
        }
        return c
    }

    public static func parseEvalSuite(_ raw: String) -> EvalSuite? {
        guard let obj = jsonObject(from: raw) else { return nil }
        var suite = EvalSuite()
        suite.judgeRubric = (obj["judge_rubric"] as? String) ?? ""
        suite.cases = (obj["cases"] as? [Any] ?? []).compactMap { item in
            guard let c = item as? [String: Any],
                  let name = c["name"] as? String else { return nil }
            return EvalCase(name: name,
                            input: (c["input"] as? String) ?? "",
                            expects: (c["expects"] as? [Any] ?? []).compactMap { $0 as? String },
                            trap: (c["trap"] as? String) ?? "")
        }
        return suite.cases.isEmpty && suite.judgeRubric.isEmpty ? nil : suite
    }

    /// Accepts both {"goal": {"note": "...", "score": 3}} and {"goal": 3}.
    private static func parseScores(_ any: Any?) -> [String: AxisVerdict] {
        guard let dict = any as? [String: Any] else { return [:] }
        var out: [String: AxisVerdict] = [:]
        for (key, value) in dict {
            // Normalise to the canonical axis name, or the score is silently dropped and the axis
            // falls back to 2 in `total` with nothing on screen to explain it.
            guard let axis = Axis.match(key) else { continue }
            if let n = value as? NSNumber {
                out[axis.rawValue] = AxisVerdict(score: n.intValue, note: "")
            } else if let d = value as? [String: Any] {
                let score = (d["score"] as? NSNumber)?.intValue ?? 2
                out[axis.rawValue] = AxisVerdict(score: score, note: (d["note"] as? String) ?? "")
            }
        }
        return out
    }
}
