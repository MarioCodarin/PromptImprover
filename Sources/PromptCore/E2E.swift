import Foundation

/// Headless end-to-end run of the pipeline, used by `--e2e`.
///
/// This is the harness that answers "does the thing actually work": it drives the same
/// `PromptEngine` the UI drives, prints a stage trace with per-stage timing, and applies the same
/// linter gate. Point it at a real endpoint, or at the mock server in `Tests/mock_llm.py` to verify
/// the plumbing without spending tokens.
public enum E2E {

    public struct Config {
        var baseURL = ""
        var key = ""
        var model = ""
        var format = APIFormat.openAI
        var draft = "make me a landing page"
        var target: PromptTarget = .agentTask
        var rigor: Rigor = .standard
        var json = false
        var outPath: String?
        /// Dollars per million tokens, supplied only by `--price-in` / `--price-out`. The
        /// provider's `/models` response carries ids, not prices, so nothing can infer this.
        var priceIn: Double?
        var priceOut: Double?
        /// Reasoning effort, when the endpoint declares one. Without this the 400 fallback for
        /// `reasoning_effort` was never reachable from the harness.
        var effort: String?
        /// Fill every clarifying question with its recorded default, so the gate's "user answered"
        /// path is exercisable. Without it the harness can only ever simulate a user who skipped
        /// every question, and `silent-defaults` fires where the app would be clean.
        var answerQuestions = false
        /// Overrides for the run's budget, so the time-limit paths are testable in seconds.
        var deadline: TimeInterval?
        var stall: TimeInterval?
    }

    public static func parse(_ args: [String]) -> Config? {
        var c = Config()
        var i = 0
        func next() -> String? { i + 1 < args.count ? args[i + 1] : nil }
        while i < args.count {
            switch args[i] {
            case "--e2e":
                if let v = next() { c.baseURL = v; i += 1 }
            case "--key":
                if let v = next() { c.key = v; i += 1 }
            case "--model":
                if let v = next() { c.model = v; i += 1 }
            case "--format":
                if let v = next() {
                    // `--format anthropc` used to run the wrong wire format with no warning, which
                    // is the same class of defect as a typo'd --rigor.
                    switch v.lowercased() {
                    case "openai", "oi", "chat": c.format = .openAI
                    case "anthropic", "messages": c.format = .anthropic
                    default:
                        FileHandle.standardError.write(Data(
                            "unknown format \(v) — use openai or anthropic\n".utf8))
                        return nil
                    }
                    i += 1
                }
            case "--draft":
                if let v = next() { c.draft = v; i += 1 }
            case "--target":
                if let v = next() {
                    // A typo silently ran the agent-task section set, so the run was graded
                    // against the wrong bar and reported PASS.
                    guard let t = PromptTarget(rawValue: v) else {
                        let names = PromptTarget.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                        FileHandle.standardError.write(Data(
                            "unknown target \(v) — use one of: \(names)\n".utf8))
                        return nil
                    }
                    c.target = t; i += 1
                }
            case "--rigor":
                if let v = next() {
                    // A typo must not buy the cheap pipeline. `deepish` used to fall back to
                    // Standard and report PASS, which is the direction that hides defects.
                    guard let r = Rigor.parse(v) else {
                        FileHandle.standardError.write(Data(
                            "unknown rigor \(v) — use one of: \(Rigor.allCases.map(\.rawValue).joined(separator: ", "))\n".utf8))
                        return nil
                    }
                    c.rigor = r; i += 1
                }
            case "--out":
                if let v = next() { c.outPath = v; i += 1 }
            case "--price-in":
                if let v = next() { c.priceIn = Double(v); i += 1 }
            case "--price-out":
                if let v = next() { c.priceOut = Double(v); i += 1 }
            case "--effort":
                if let v = next() {
                    // Sent verbatim as `reasoning_effort`, so `--effort loww` reached the provider
                    // and failed there with a 400 that read like a model problem. The accepted
                    // values are the ones the wire format defines.
                    let allowed = ["low", "medium", "high", "none", "minimal", "xhigh"]
                    guard allowed.contains(v.lowercased()) else {
                        FileHandle.standardError.write(Data(
                            "unknown effort \(v) — use one of: \(allowed.joined(separator: ", "))\n".utf8))
                        return nil
                    }
                    c.effort = v.lowercased(); i += 1
                }
            case "--answer-questions":
                c.answerQuestions = true
            case "--deadline":
                guard let v = next().flatMap(Double.init), v > 0 else { return nil }
                c.deadline = v; i += 1
            case "--stall":
                guard let v = next().flatMap(Double.init), v > 0 else { return nil }
                c.stall = v; i += 1
            case "--json":
                c.json = true
            default: break
            }
            i += 1
        }
        guard !c.baseURL.isEmpty else { return nil }
        return c
    }

    /// Drives `PromptPipeline`, the same orchestration the app uses, and prints what happened.
    public static func run(_ c: Config) async -> Int32 {
        let endpoint = Endpoint(name: "e2e", baseURL: c.baseURL, format: c.format,
                                models: [c.model], selectedModel: c.model,
                                reasoningEffort: c.effort)
        let client = LLMClient(endpoint: endpoint, apiKey: c.key)
        let pipeline = PromptPipeline(request: .init(draft: c.draft, target: c.target, rigor: c.rigor,
                                                     model: c.model, profile: nil),
                                      transport: client)
        let started = Date()
        // The app's budget unless a flag overrides it; an override applies to every call.
        var fixed: Budget?
        if c.deadline != nil || c.stall != nil {
            var b = Budget.for(c.rigor, from: started)
            if let d = c.deadline { b.deadline = started.addingTimeInterval(d) }
            if let s = c.stall { b.stallTimeout = s }
            fixed = b
        }

        var calls = 0
        var stageTimes: [String: Double] = [:]
        var current: (name: String, start: Date)?
        func stamp(_ next: String?) {
            if let cur = current { stageTimes[cur.name, default: 0] += Date().timeIntervalSince(cur.start) }
            current = next.map { ($0, Date()) }
        }

        do {
            // Clarify. Fast skips it, exactly like the app.
            var diagnosis: Diagnosis?
            var questions: [ClarifyingQuestion] = []
            if c.rigor.verifies {
                stamp("clarify")
                let d: Diagnosis
                if let fixed { d = try await pipeline.clarify(budget: fixed) } else { d = try await pipeline.clarify() }
                calls += 1
                diagnosis = d
                log("clarify", "\(d.findings.count) findings, \(d.questions.count) questions, risk \(d.risk)")
                // The harness has no user: it skips every question (the worst case), or accepts
                // every recorded default with `--answer-questions`.
                questions = c.answerQuestions ? d.questions.map { q in
                    var copy = q; copy.answer = q.default; return copy
                } : d.questions
            } else {
                log("clarify", "skipped (Fast)")
            }

            var result: PromptPipeline.Result?
            var sawRepair = false
            for try await event in pipeline.compose(diagnosis: diagnosis, questions: questions,
                                                    priorCalls: calls, budget: fixed) {
                switch event {
                case .stage(let s):
                    stamp(s.rawValue)
                case .partial:
                    break
                case .lint(let r):
                    if !sawRepair { log("lint", "\(r.score)/100 — \(r.summary)") }
                case .critique(let cr):
                    log("review", "\(cr.verdict), \(cr.issues.count) issues")
                case .repair(let outcome):
                    sawRepair = true
                    switch outcome {
                    case .applied: log("repair", "accepted")
                    case .reverted(let why): log("repair", "rejected — \(why), kept original")
                    case .none: break
                    }
                case .tests(let suite):
                    log("tests", "\(suite.cases.count) cases")
                case .finished(let r):
                    stamp(nil)
                    result = r
                }
            }
            guard let r = result else { return bail("the pipeline ended without a result") }
            calls = r.calls

            let cost = client.usage.cost(inputPerM: c.priceIn, outputPerM: c.priceOut,
                                         readRatio: c.format == .anthropic ? 0.1 : 0.5)
            print("")
            print("── result ─────────────────────────────────────────")
            print("calls \(calls) · \(String(format: "%.1f", r.elapsed + (stageTimes["clarify"] ?? 0)))s · structure \(r.lint.score)/100"
                  + (r.critique.map { " · review \($0.issues.count) issues" } ?? ""))
            if r.endedBy == .timedOut { print("ended: time limit — later stages skipped, prompt kept") }
            print("tokens \(client.usage.summary)" + (cost.map { String(format: " · $%.5f", $0) } ?? ""))
            print("gate: " + (r.lint.isClean ? "PASS" : "FAIL — " + r.lint.issues.map(\.title).joined(separator: "; ")))
            print("───────────────────────────────────────────────────")
            print(r.prompt)
            if let suite = r.tests, !suite.cases.isEmpty {
                print("")
                print(suite.markdown)
            }

            if let path = c.outPath {
                // The prompt and its tests are separate deliverables.
                try r.prompt.write(toFile: path, atomically: true, encoding: .utf8)
                print("\nwrote \(path)")
                if let suite = r.tests {
                    let testsPath = (path as NSString).deletingPathExtension + ".tests.md"
                    try suite.markdown.write(toFile: testsPath, atomically: true, encoding: .utf8)
                    print("wrote \(testsPath)")
                }
            }
            if c.json {
                let payload: [String: Any] = [
                    "calls": calls,
                    "tokens_in": client.usage.inputTokens,
                    "tokens_out": client.usage.outputTokens,
                    // `null`, not -1: no price flags means the cost was never computed.
                    "cost_usd": cost.map { $0 as Any } ?? NSNull(),
                    "structure": r.lint.score,
                    "review_issues": r.critique.map { $0.issues.count as Any } ?? NSNull(),
                    "timed_out": r.endedBy == .timedOut,
                    "clean": r.lint.isClean,
                    "issues": r.lint.issues.map { ["id": $0.id, "severity": $0.severity.rawValue, "title": $0.title] },
                    "stages": stageTimes,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: c.outPath.map { $0 + ".json" } ?? "e2e-result.json"))
                }
            }
            return r.lint.isClean ? 0 : 1
        } catch {
            // A failed run still spent tokens; report the spend with the error.
            if client.usage.inputTokens > 0 {
                FileHandle.standardError.write(Data("spent: \(client.usage.summary)\n".utf8))
            }
            return bail(error.localizedDescription)
        }
    }

    private static func log(_ stage: String, _ message: String) {
        print(String(format: "%-9@ %@", stage as NSString, message))
    }

    private static func bail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("e2e failed: \(message)\n".utf8))
        return 2
    }
}
