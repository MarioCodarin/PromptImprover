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
            case "--json":
                c.json = true
            default: break
            }
            i += 1
        }
        guard !c.baseURL.isEmpty else { return nil }
        return c
    }

    public static func run(_ c: Config) async -> Int32 {
        let endpoint = Endpoint(name: "e2e", baseURL: c.baseURL, format: c.format,
                                models: [c.model], selectedModel: c.model,
                                reasoningEffort: c.effort)
        let client = LLMClient(endpoint: endpoint, apiKey: c.key)
        let engine = PromptEngine(client: client, model: c.model, target: c.target,
                                  profile: nil, draft: c.draft)

        var calls = 0
        var stageTimes: [(String, Double)] = []
        func stamp(_ name: String, _ start: Date) { stageTimes.append((name, Date().timeIntervalSince(start))) }

        do {
            // Stage 1. Fast skips it, exactly like the app: one call, no questions, no critique.
            var t = Date()
            var diagnosis = Diagnosis()
            if c.rigor.verifies {
                diagnosis = try await engine.diagnose()
                calls += 1
                stamp("diagnose", t)
                log("diagnose", "\(diagnosis.findings.count) findings, \(diagnosis.questions.count) questions, risk \(diagnosis.risk)")
            } else {
                log("diagnose", "skipped (Fast)")
            }

            // Stage 2
            t = Date()
            let brief = MetaPrompts.composeBrief(draft: c.draft, diagnosis: diagnosis, questions: diagnosis.questions)
            var raw = ""
            for try await partial in engine.write(brief: brief) { raw = partial }
            calls += 1
            stamp("write", t)
            var prompt = PromptEngine.finalize(raw)
            guard !prompt.isEmpty else { return bail("writer returned nothing") }
            log("write", "\(prompt.split(whereSeparator: \.isWhitespace).count) words")

            // Mirrors the app: a question counts as unanswered when the user left it blank. The
            // harness has no user, so it either skips every question (the default, worst case) or
            // accepts every recorded default when `--answer-questions` is set.
            let answered = c.answerQuestions ? diagnosis.questions.map { q -> ClarifyingQuestion in
                var copy = q
                copy.answer = q.default
                return copy
            } : diagnosis.questions
            let unanswered = answered.filter {
                $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
            var lint = PromptLinter.lint(prompt, target: c.target,
                                         unansweredQuestions: unanswered, draft: c.draft)
            log("lint", "\(lint.score)/100 — \(lint.summary)")

            // Stage 3
            var critique: Critique?
            if c.rigor.verifies {
                t = Date()
                critique = try await engine.verify(prompt: prompt)
                calls += 1
                stamp("verify", t)
                if let critique {
                    log("verify", "\(critique.verdict), \(critique.issues.count) issues, rubric \(critique.total(for: c.target))/100")
                } else {
                    log("verify", "unparseable verdict — keeping the prompt")
                }
            }

            // Stage 4. The same policy the app uses, from the same module: the union of the
            // critic's issues and the gate's blockers/majors, judged by RepairGuard. This used to
            // be re-implemented here and had drifted.
            //
            // An unparseable verdict is not an exemption. `critique.map { … } ?? []` skipped the
            // gate whenever the critic's JSON failed to parse, so a stray brace in its prose
            // switched off the deterministic half of the gate — the exact opposite of what the
            // gate is for. An empty critique says nothing, which leaves the gate's issues.
            let repairIssues = RepairGuard.issues(critique: critique ?? Critique(), lint: lint)
            if c.rigor.repairs, !repairIssues.isEmpty {
                t = Date()
                var repaired = ""
                for try await partial in engine.repair(prompt: prompt, issues: repairIssues) { repaired = partial }
                calls += 1
                stamp("repair", t)
                let revised = PromptEngine.finalize(repaired)
                let after = PromptLinter.lint(revised, target: c.target,
                                              unansweredQuestions: unanswered, draft: c.draft)
                let verdict = RepairGuard.judge(before: lint, after: after, revised: revised)
                if verdict.note == nil {
                    prompt = revised
                    lint = after
                    log("repair", "accepted — structure \(after.score)/100")
                    // Re-score the shipped prompt so the rubric number describes what was produced,
                    // not what it replaced.
                    let before = critique?.total(for: c.target)
                    t = Date()
                    // Same tolerance as the app: losing the re-check is not losing the prompt.
                    do {
                        critique = try await engine.verify(prompt: prompt)
                        calls += 1
                        stamp("reverify", t)
                        log("reverify", reverified(critique, was: before, target: c.target))
                    } catch {
                        // Losing the re-check is not losing the prompt: keep the text, drop the
                        // score. The previous critique described the pre-repair text.
                        critique = nil
                        log("reverify", "failed (\(error.localizedDescription)) — kept the repaired prompt, dropped the score")
                    }
                } else {
                    log("repair", "rejected — \(verdict.note ?? "unknown"), kept original")
                }
            }

            // Stage 5
            var suite: EvalSuite?
            if c.rigor.writesTests {
                t = Date()
                // Tests are a bonus; losing them must not lose the prompt. Mirrors writeTests().
                do {
                    suite = try await engine.tests(prompt: prompt)
                    calls += 1
                    stamp("tests", t)
                    log("tests", "\(suite?.cases.count ?? 0) cases")
                } catch {
                    log("tests", "failed (\(error.localizedDescription)) — prompt kept")
                }
            }

            let total = stageTimes.reduce(0) { $0 + $1.1 }
            let cost = client.usage.cost(inputPerM: c.priceIn, outputPerM: c.priceOut,
                                         readRatio: c.format == .anthropic ? 0.1 : 0.5)
            print("")
            print("── result ─────────────────────────────────────────")
            print("calls \(calls) · \(String(format: "%.1f", total))s · structure \(lint.score)/100"
                  + (critique.map { " · rubric \($0.total(for: c.target))/100" } ?? ""))
            print("tokens \(client.usage.summary)" + (cost.map { String(format: " · $%.5f", $0) } ?? ""))
            print("gate: " + (lint.isClean ? "PASS" : "FAIL — " + lint.issues.map(\.title).joined(separator: "; ")))
            print("───────────────────────────────────────────────────")
            print(prompt)
            if let suite, !suite.cases.isEmpty {
                print("")
                print(suite.markdown)
            }

            if let path = c.outPath {
                // The prompt and its tests are separate deliverables. Appending the suite to the
                // prompt file yields something you cannot paste into a system slot.
                try prompt.write(toFile: path, atomically: true, encoding: .utf8)
                print("\nwrote \(path)")
                if let suite {
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
                    // `null`, not -1: a sentinel that looks like a measurement gets averaged by
                    // the next script that reads this file. No price flags means the cost was
                    // never computed, which is an absence, not a negative number.
                    "cost_usd": cost.map { $0 as Any } ?? NSNull(),
                    "structure": lint.score,
                    "rubric": critique.map { $0.total(for: c.target) as Any } ?? NSNull(),
                    "clean": lint.isClean,
                    "issues": lint.issues.map { ["id": $0.id, "severity": $0.severity.rawValue, "title": $0.title] },
                    // Reduced, not `uniqueKeysWithValues`: a stage stamped twice would trap, and
                    // the harness exists to report failures rather than become one.
                    "stages": stageTimes.reduce(into: [String: Double]()) { $0[$1.0] = $1.1 },
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: c.outPath.map { $0 + ".json" } ?? "e2e-result.json"))
                }
            }
            return lint.isClean ? 0 : 1
        } catch {
            // A failed run still spent tokens. Reporting the error without the spend hides the
            // only number that matters when a stage is failing repeatedly.
            if calls > 0 || client.usage.inputTokens > 0 {
                FileHandle.standardError.write(Data("spent: \(client.usage.summary)\n".utf8))
            }
            return bail(error.localizedDescription)
        }
    }

    /// The re-check line.
    ///
    /// Two rubric scores printed next to each other are an invitation to subtract them, and the
    /// difference is usually inside the critic's own spread. `RubricNoise` decides whether the gap
    /// is reportable, so the log stops handing the reader a regression that is not there.
    private static func reverified(_ c: Critique?, was before: Int?, target: PromptTarget) -> String {
        guard let c else { return "unparseable" }
        let after = c.total(for: target)
        var line = "\(c.verdict), rubric \(after)/100"
        if let before {
            line += " (was \(before) — \(RubricNoise.delta(from: before, to: after).note))"
        }
        return line
    }

    private static func log(_ stage: String, _ message: String) {
        print(String(format: "%-9@ %@", stage as NSString, message))
    }

    private static func bail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("e2e failed: \(message)\n".utf8))
        return 2
    }
}
