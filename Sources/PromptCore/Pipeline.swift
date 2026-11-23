import Foundation

/// The whole prompt pipeline, and the only place its order is decided.
///
/// The app and the `--e2e` harness used to each drive `PromptEngine` themselves, and the two drifted
/// (the code comments record several bugs from it). Both now consume this type's event stream.
///
/// The flow follows what the literature says pays off on a strong model, and drops what does not:
/// - **Clarify** first, because the gain from rewriting a prompt comes from information the draft
///   lacked, not from restyling it (BPO, arXiv 2311.04155; scale study, arXiv 2505.08303).
/// - **Write once**, then lint deterministically. The linter is free, offline and not noisy.
/// - **Repair at most once**, from concrete quoted feedback (GEPA's reflective mutation, arXiv
///   2507.19457; Self-Refine, arXiv 2303.17651, where most of the gain is the first iteration).
///   Standard repairs from the linter alone, so a clean prompt costs two calls in total.
/// - **Deep** adds one independent review and acceptance tests.
///
/// Every call runs under one `Budget`. When it expires the run ends with the best finished prompt
/// it has, marked `.timedOut`, instead of spinning.
public struct PromptPipeline {
    public struct Request {
        public var draft: String
        public var target: PromptTarget
        public var rigor: Rigor
        public var model: String
        public var profile: String?

        public init(draft: String, target: PromptTarget, rigor: Rigor, model: String, profile: String? = nil) {
            self.draft = draft; self.target = target; self.rigor = rigor
            self.model = model; self.profile = profile
        }
    }

    public enum Stage: String, Sendable {
        case clarify, write, review, repair, tests
    }

    public enum RepairOutcome: Equatable, Sendable {
        case none, applied
        case reverted(String)
    }

    public enum EndReason: Equatable, Sendable {
        case complete, timedOut
    }

    /// A prompt that has been written in full and linted. The only thing a run may hand back.
    public struct Candidate {
        public var text: String
        public var lint: PromptLinter.Report
    }

    public struct Result {
        public var prompt: String
        public var lint: PromptLinter.Report
        public var critique: Critique?
        public var tests: EvalSuite?
        public var repair: RepairOutcome
        public var endedBy: EndReason
        /// Model calls this run completed, counting the clarify call when there was one.
        public var calls: Int
        public var elapsed: TimeInterval
        public var tokensIn: Int
        public var tokensOut: Int
        /// The conversation that produced `prompt`, for a later refine.
        public var history: [ChatMessage]
    }

    public enum Event {
        case stage(Stage)
        /// Text as it streams. A fragment until `.finished`; never something to copy.
        case partial(String)
        case lint(PromptLinter.Report)
        case critique(Critique)
        case repair(RepairOutcome)
        case tests(EvalSuite)
        case finished(Result)
    }

    public let request: Request
    let engine: PromptEngine
    let transport: any LLMTransport

    public init(request: Request, transport: any LLMTransport) {
        self.request = request
        self.transport = transport
        self.engine = PromptEngine(client: transport, model: request.model, target: request.target,
                                   profile: request.profile, draft: request.draft)
    }

    /// Below this much budget, a repair is not started: it would be cut off and thrown away.
    static let minimumRepairTime: TimeInterval = 20

    // MARK: - Stage 1: clarify

    /// The questions and defaults, before anything is written. Separate from `compose` so the
    /// caller can show the questions without the pipeline holding a suspended run open; the write
    /// budget starts when writing does, not while the user is typing answers.
    ///
    /// Running out of time here is not a failure: the writer works without a diagnosis (Fast
    /// always does), so a slow clarify degrades to "no questions" instead of ending the run.
    public func clarify(budget: Budget = Budget(deadline: Date().addingTimeInterval(90))) async throws -> Diagnosis {
        do {
            return try await engine.diagnose(budget: budget)
        } catch LLMError.deadline {
            return .empty
        }
    }

    /// The write is the one call a run cannot do without, so it is not held to the depth budget:
    /// at reasoning effort "max" a model can think for minutes before its first word, and cutting
    /// it off left the user with nothing. Only the stall limits and this hard cap apply.
    static let writeCap: TimeInterval = 600

    // MARK: - Stages 2-5: write, lint, review, repair, tests

    /// - Parameters:
    ///   - diagnosis: from `clarify`, or nil when the depth skips it.
    ///   - questions: the clarify questions with whatever the user answered.
    ///   - priorCalls: calls already spent on this run (the clarify call), so the total is honest.
    ///   - budget: one budget for every call, write included (the harness uses this to test the
    ///     limits). When nil, the write runs under `writeCap` and the depth budget is the time
    ///     allowed *after* a prompt exists, for review, repair and tests.
    public func compose(diagnosis: Diagnosis?, questions: [ClarifyingQuestion] = [],
                        priorCalls: Int = 0, budget fixed: Budget? = nil) -> AsyncThrowingStream<Event, Error> {
        let started = Date()
        let writeBudget = fixed ?? Budget(deadline: started.addingTimeInterval(Self.writeCap))
        let unanswered = questions.filter { $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let brief = MetaPrompts.composeBrief(draft: request.draft, diagnosis: diagnosis ?? .empty, questions: questions)

        return AsyncThrowingStream { out in
            let task = Task {
                var calls = priorCalls
                func lint(_ text: String) -> PromptLinter.Report {
                    PromptLinter.lint(text, target: request.target, unansweredQuestions: unanswered, draft: request.draft)
                }
                func finish(_ best: Candidate, critique: Critique?, tests: EvalSuite?,
                            repair: RepairOutcome, endedBy: EndReason) {
                    out.yield(.finished(Result(prompt: best.text, lint: best.lint, critique: critique, tests: tests,
                                               repair: repair, endedBy: endedBy, calls: calls,
                                               elapsed: Date().timeIntervalSince(started),
                                               tokensIn: transport.usage.inputTokens,
                                               tokensOut: transport.usage.outputTokens,
                                               history: [.user(brief)])))
                    out.finish()
                }

                do {
                    // Write. A deadline here has nothing to fall back on, so it is an error.
                    out.yield(.stage(.write))
                    let written = try await streamed(engine.write(brief: brief, budget: writeBudget), into: out)
                    // From here on a finished prompt exists, so the rest is optional work with a
                    // fixed allowance that starts now.
                    let budget = fixed ?? .for(request.rigor)
                    calls += 1
                    let text = PromptEngine.finalize(written)
                    guard !text.isEmpty else { throw LLMError.api("The model returned an empty response.") }
                    var best = Candidate(text: text, lint: lint(text))
                    // The finalized text replaces the last streamed one (which may still carry a
                    // wrapper fence) before `.lint`: a consumer saves the text on screen as the
                    // prompt that score describes.
                    out.yield(.partial(text))
                    out.yield(.lint(best.lint))

                    guard request.rigor.verifies else {
                        return finish(best, critique: nil, tests: nil, repair: .none, endedBy: .complete)
                    }

                    // Review (Deep only). A failure here costs the review, never the prompt.
                    var critique: Critique?
                    if request.rigor.writesTests {
                        out.yield(.stage(.review))
                        do {
                            critique = try await engine.verify(prompt: best.text, budget: budget)
                            calls += 1
                            if let critique { out.yield(.critique(critique)) }
                        } catch LLMError.deadline {
                            return finish(best, critique: nil, tests: nil, repair: .none, endedBy: .timedOut)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            if Task.isCancelled { throw CancellationError() }
                            critique = nil
                        }
                    }

                    // Repair, at most once, only for blockers and majors.
                    var repair = RepairOutcome.none
                    let issues = RepairGuard.issues(critique: critique ?? .empty, lint: best.lint)
                    if !issues.isEmpty {
                        guard budget.remaining > Self.minimumRepairTime else {
                            return finish(best, critique: critique, tests: nil,
                                          repair: .reverted("not enough time left for a repair"), endedBy: .timedOut)
                        }
                        out.yield(.stage(.repair))
                        var partial = ""
                        do {
                            for try await p in engine.repair(prompt: best.text, issues: issues, budget: budget) {
                                partial = p
                                out.yield(.partial(p))
                            }
                            // A cancelled stream ends quietly, without throwing. Without this a
                            // fragment was judged, accepted, and the tests call still went out.
                            try Task.checkCancellation()
                            calls += 1
                            let revised = PromptEngine.finalize(partial)
                            let after = lint(revised)
                            let verdict = RepairGuard.judge(before: best.lint, after: after, revised: revised)
                            if let why = verdict.note {
                                repair = .reverted(why)
                            } else {
                                best = Candidate(text: revised, lint: after)
                                repair = .applied
                            }
                        } catch LLMError.deadline {
                            let kept = Self.afterRepairCutOff(before: best, partial: PromptEngine.finalize(partial), lint: lint)
                            out.yield(.partial(kept.text))
                            out.yield(.lint(kept.lint))
                            return finish(kept, critique: critique, tests: nil,
                                          repair: kept.text == best.text ? .reverted("the repair ran out of time") : .applied,
                                          endedBy: .timedOut)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // URLSession reports a cancel as `URLError.cancelled`, not CancellationError.
                            if Task.isCancelled { throw CancellationError() }
                            // A failed repair is a lost improvement, not a lost prompt.
                            repair = .reverted("the repair call failed: \(error.localizedDescription)")
                        }
                        // Whatever happened, the text on screen is now `best`, not the stream.
                        out.yield(.partial(best.text))
                        out.yield(.lint(best.lint))
                        out.yield(.repair(repair))
                    }

                    // Tests (Deep only). A bonus: losing them never loses the prompt.
                    var suite: EvalSuite?
                    if request.rigor.writesTests {
                        guard !budget.isExpired else {
                            return finish(best, critique: critique, tests: nil, repair: repair, endedBy: .timedOut)
                        }
                        out.yield(.stage(.tests))
                        do {
                            suite = try await engine.tests(prompt: best.text, budget: budget)
                            calls += 1
                            if let suite { out.yield(.tests(suite)) }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            if Task.isCancelled { throw CancellationError() }
                            suite = nil
                        }
                    }
                    finish(best, critique: critique, tests: suite, repair: repair,
                           endedBy: budget.isExpired ? .timedOut : .complete)
                } catch {
                    out.finish(throwing: error)
                }
            }
            out.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Refine

    /// One revision of a finished prompt. Write and lint only: the user is steering by hand.
    public func refine(current: String, history: [ChatMessage], instruction: String,
                       priorCalls: Int = 0) -> AsyncThrowingStream<Event, Error> {
        let started = Date()
        let messages = history + [.assistant(current), .user(MetaPrompts.refineInstruction(instruction))]
        return AsyncThrowingStream { out in
            let task = Task {
                do {
                    out.yield(.stage(.write))
                    // No deadline: one call the user is watching, and a full rewrite on a reasoning
                    // model can pass a minute. The stall watchdog still ends a dead stream.
                    let raw = try await streamed(engine.revise(history: messages, budget: .unbounded()), into: out)
                    let text = PromptEngine.finalize(raw)
                    guard !text.isEmpty else { throw LLMError.api("The model returned an empty response.") }
                    let report = PromptLinter.lint(text, target: request.target, unansweredQuestions: 0, draft: request.draft)
                    out.yield(.partial(text))
                    out.yield(.lint(report))
                    out.yield(.finished(Result(prompt: text, lint: report, critique: nil, tests: nil, repair: .none,
                                               endedBy: .complete, calls: priorCalls + 1,
                                               elapsed: Date().timeIntervalSince(started),
                                               tokensIn: transport.usage.inputTokens,
                                               tokensOut: transport.usage.outputTokens,
                                               history: messages)))
                    out.finish()
                } catch {
                    out.finish(throwing: error)
                }
            }
            out.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    /// Forwards a stage's partial text and returns the last value.
    private func streamed(_ stream: AsyncThrowingStream<String, Error>,
                          into out: AsyncThrowingStream<Event, Error>.Continuation) async throws -> String {
        var last = ""
        for try await partial in stream {
            last = partial
            out.yield(.partial(partial))
        }
        try Task.checkCancellation()
        return last
    }

    /// What to ship when the deadline cuts a repair off mid-stream.
    ///
    /// `before` is the complete, linted prompt the repair started from. `partial` is however much
    /// of the rewrite arrived — anything from nothing to all but the last line. `lint` scores text.
    static func afterRepairCutOff(before: Candidate, partial: String,
                                  lint: (String) -> PromptLinter.Report) -> Candidate {
        // TODO(human): decide what the user gets when time runs out during a repair.
        return before
    }
}
