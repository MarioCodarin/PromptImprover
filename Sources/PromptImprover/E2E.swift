import Foundation

/// Headless end-to-end run of the pipeline, used by `--e2e`.
///
/// This is the harness that answers "does the thing actually work": it drives the same
/// `PromptEngine` the UI drives, prints a stage trace with per-stage timing, and applies the same
/// linter gate. Point it at a real endpoint, or at the mock server in `Tests/mock_llm.py` to verify
/// the plumbing without spending tokens.
enum E2E {

    struct Config {
        var baseURL = ""
        var key = ""
        var model = ""
        var format = APIFormat.openAI
        var draft = "make me a landing page"
        var target: PromptTarget = .agentTask
        var rigor: Rigor = .standard
        var json = false
        var outPath: String?
        /// Dollars per million tokens, taken from the provider's /models pricing block.
        var priceIn: Double?
        var priceOut: Double?
    }

    static func parse(_ args: [String]) -> Config? {
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
                if let v = next() { c.format = v.lowercased() == "anthropic" ? .anthropic : .openAI; i += 1 }
            case "--draft":
                if let v = next() { c.draft = v; i += 1 }
            case "--target":
                if let v = next() { c.target = PromptTarget(rawValue: v) ?? .agentTask; i += 1 }
            case "--rigor":
                if let v = next() { c.rigor = Rigor(rawValue: v) ?? .standard; i += 1 }
            case "--out":
                if let v = next() { c.outPath = v; i += 1 }
            case "--price-in":
                if let v = next() { c.priceIn = Double(v); i += 1 }
            case "--price-out":
                if let v = next() { c.priceOut = Double(v); i += 1 }
            case "--json":
                c.json = true
            default: break
            }
            i += 1
        }
        guard !c.baseURL.isEmpty else { return nil }
        return c
    }

    static func run(_ c: Config) async -> Int32 {
        let endpoint = Endpoint(name: "e2e", baseURL: c.baseURL, format: c.format,
                                models: [c.model], selectedModel: c.model)
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

            let unanswered = diagnosis.questions.filter { $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
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

            // Stage 4
            if c.rigor.repairs, let reviewed = critique, reviewed.needsRepair, !reviewed.issues.isEmpty {
                t = Date()
                var repaired = ""
                for try await partial in engine.repair(prompt: prompt, issues: reviewed.issues) { repaired = partial }
                calls += 1
                stamp("repair", t)
                let revised = PromptEngine.finalize(repaired)
                let after = PromptLinter.lint(revised, target: c.target,
                                              unansweredQuestions: unanswered, draft: c.draft)
                if !revised.isEmpty, after.score >= lint.score {
                    prompt = revised
                    lint = after
                    log("repair", "accepted — structure \(after.score)/100")
                    // Re-score the shipped prompt so the rubric number describes what was produced,
                    // not what it replaced.
                    t = Date()
                    // Same tolerance as the app: losing the re-check is not losing the prompt.
                    do {
                        critique = try await engine.verify(prompt: prompt)
                        calls += 1
                        stamp("reverify", t)
                        log("reverify", critique.map { "\($0.verdict), rubric \($0.total(for: c.target))/100" } ?? "unparseable")
                    } catch {
                        log("reverify", "failed (\(error.localizedDescription)) — kept the repaired prompt")
                    }
                } else {
                    log("repair", "rejected — \(after.score)/100 < \(lint.score)/100, kept original")
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
            let cost = client.usage.cost(inputPerM: c.priceIn, outputPerM: c.priceOut)
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
                    "cost_usd": cost ?? -1,
                    "structure": lint.score,
                    "rubric": critique.map { $0.total(for: c.target) } ?? -1,
                    "clean": lint.isClean,
                    "issues": lint.issues.map { ["id": $0.id, "severity": $0.severity.rawValue, "title": $0.title] },
                    "stages": Dictionary(uniqueKeysWithValues: stageTimes.map { ($0.0, $0.1) }),
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: c.outPath.map { $0 + ".json" } ?? "e2e-result.json"))
                }
            }
            return lint.isClean ? 0 : 1
        } catch {
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
