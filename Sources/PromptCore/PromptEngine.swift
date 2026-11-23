import Foundation

/// The model calls, one per stage, with no orchestration. `PromptPipeline` decides which run and
/// when; this type only knows how to make each one and parse its reply.
///
/// Every call takes the run's `Budget` and names its `CallKind`, so the output ceiling, JSON mode
/// and reasoning effort are decided in one table (`CallKind`) instead of at each call site.
public struct PromptEngine {
    public let transport: any LLMTransport
    public let model: String
    public let target: PromptTarget
    public let profile: String?
    public let draft: String

    public init(client: any LLMTransport, model: String, target: PromptTarget, profile: String?, draft: String) {
        self.transport = client; self.model = model; self.target = target
        self.profile = profile; self.draft = draft
    }

    private func options(_ kind: CallKind, _ budget: Budget) -> LLMClient.Options {
        .call(kind, budget: budget, endpointEffort: transport.defaultEffort)
    }

    /// Clarify. Returns a diagnosis even when the JSON is unusable, so the writer is never blocked.
    public func diagnose(budget: Budget = .unbounded()) async throws -> Diagnosis {
        let system = MetaPrompts.personalize(MetaPrompts.analyzer(target: target), profile: profile)
        let raw = try await transport.complete(system: system,
                                               messages: [.user(MetaPrompts.analyzerInput(draft, target: target))],
                                               model: model, options: options(.clarify, budget))
        return ResponseParsing.parseDiagnosis(raw)
    }

    /// Write. Yields the accumulated text after every chunk, so a cut-off run still has a prefix.
    public func write(brief: String, budget: Budget = .unbounded()) -> AsyncThrowingStream<String, Error> {
        stream(system: MetaPrompts.writer(target: target), messages: [.user(brief)], kind: .write, budget: budget)
    }

    /// Review (Deep only). Nil means the reply could not be parsed: not a reason to discard the prompt.
    public func verify(prompt: String, budget: Budget = .unbounded()) async throws -> Critique? {
        let raw = try await transport.complete(system: MetaPrompts.critic(target: target),
                                               messages: [.user(MetaPrompts.criticInput(prompt: prompt, draft: draft, target: target))],
                                               model: model, options: options(.critique, budget))
        return ResponseParsing.parseCritique(raw)
    }

    /// Repair. One targeted rewrite from concrete, quoted feedback (GEPA's reflective mutation).
    public func repair(prompt: String, issues: [CritiqueIssue], budget: Budget = .unbounded()) -> AsyncThrowingStream<String, Error> {
        stream(system: MetaPrompts.repair,
               messages: [.user(MetaPrompts.repairInput(prompt: prompt, issues: issues, target: target,
                                                        draft: draft, lengthTarget: target.lengthTarget))],
               kind: .repair, budget: budget)
    }

    /// Acceptance tests (Deep only). Nil on failure: tests are a bonus and must never cost the prompt.
    public func tests(prompt: String, budget: Budget = .unbounded()) async throws -> EvalSuite? {
        let raw = try await transport.complete(system: MetaPrompts.evalSuite(target: target),
                                               messages: [.user(MetaPrompts.evalInput(prompt: prompt, target: target))],
                                               model: model, options: options(.tests, budget))
        return ResponseParsing.parseEvalSuite(raw)
    }

    /// Refine: a revision of the whole prompt with the conversation so far as context.
    public func revise(history: [ChatMessage], budget: Budget = .unbounded()) -> AsyncThrowingStream<String, Error> {
        stream(system: MetaPrompts.writer(target: target), messages: history, kind: .refine, budget: budget)
    }

    // MARK: - Streaming plumbing

    private func stream(system: String, messages: [ChatMessage], kind: CallKind,
                        budget: Budget) -> AsyncThrowingStream<String, Error> {
        let base = MetaPrompts.personalize(system, profile: profile)
        let opts = options(kind, budget)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var raw = ""
                do {
                    for try await chunk in transport.stream(system: base, messages: messages, model: model, options: opts) {
                        if Task.isCancelled { break }
                        raw += chunk
                        continuation.yield(ResponseParsing.stripThinking(raw))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Final form of a streamed reply: thinking stripped, one wrapper fence removed, trimmed.
    public static func finalize(_ raw: String) -> String { ResponseParsing.finalize(raw) }
}
