import Foundation

/// Turns what a model returned into the pipeline's own types.
///
/// Kept apart from `MetaPrompts` on purpose: prompt text changes when the doctrine changes,
/// parsing changes when a model misbehaves, and the two have no reason to be edited together.
enum ResponseParsing {

    // MARK: - Output hygiene

    /// Everything a streamed reply needs before it can be judged: reasoning blocks removed, and a
    /// wrapper fence stripped. Idempotent, so a repair that re-emits clean text is unaffected.
    static func finalize(_ raw: String) -> String { unfence(stripThinking(raw)) }

    /// Removes <think>…</think> blocks some reasoning models emit inline: an unclosed one mid-stream, and an
    /// orphan </think> (chat templates that put the opening tag in the prompt, so only the closing tag comes back).
    static func stripThinking(_ s: String) -> String {
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
    static func unfence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = t.components(separatedBy: "\n")
        let fences = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        guard lines.count >= 3, fences == [0, lines.count - 1],
              lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```" else { return t }
        return lines[1..<(lines.count - 1)].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tolerant JSON

    /// Pulls the first complete JSON object out of a model reply. Models wrap JSON in prose, fences, or
    /// emit a second object afterwards; a brace counter that respects string literals handles all three.
    static func jsonObject(from raw: String) -> [String: Any]? {
        let text = unfence(stripThinking(raw))
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var end: String.Index?

        var i = start
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { end = i; break }
                }
            }
            i = text.index(after: i)
        }
        guard let end else { return nil }
        let slice = text[start...end]
        return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
    }

    static func parseDiagnosis(_ raw: String) -> Diagnosis {
        var d = Diagnosis()
        guard let obj = jsonObject(from: raw) else { return d }

        d.brief = (obj["brief"] as? String) ?? ""
        d.taskType = (obj["task_type"] as? String) ?? ""
        d.risk = (obj["risk"] as? String) ?? "low"
        d.assumptions = (obj["assumptions"] as? [Any] ?? []).compactMap { $0 as? String }

        d.findings = (obj["findings"] as? [Any] ?? []).compactMap { item in
            guard let f = item as? [String: Any],
                  let code = f["code"] as? String else { return nil }
            let sev = Defect.Severity(rawValue: (f["severity"] as? String ?? "minor").lowercased())
                ?? Defect.severity(for: code)
            return Finding(code: code.uppercased(),
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

    static func parseCritique(_ raw: String) -> Critique? {
        guard let obj = jsonObject(from: raw) else { return nil }
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

    static func parseEvalSuite(_ raw: String) -> EvalSuite? {
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
