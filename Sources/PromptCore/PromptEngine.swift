import Foundation

/// The pipeline's stages, with no UI attached.
///
/// The view model owns the interactive parts (asking questions, showing partial text, cancelling);
/// this type owns the model calls and the parsing. That split is what makes the pipeline testable:
/// `--e2e` drives exactly these functions against a real endpoint, and a mock server exercises the
/// same code path the app uses in production.
public struct PromptEngine {
    public let client: LLMClient
    public let model: String
    public let target: PromptTarget
    public let profile: String?
    public let draft: String

    public init(client: LLMClient, model: String, target: PromptTarget, profile: String?, draft: String) {
        self.client = client; self.model = model; self.target = target
        self.profile = profile; self.draft = draft
    }

    /// Stage 1. Returns a diagnosis even when the model's JSON is unusable, so the writer is never blocked.
    public func diagnose() async throws -> Diagnosis {
        let system = MetaPrompts.personalize(MetaPrompts.analyzer(target: target), profile: profile)
        let raw = try await client.complete(system: system,
                                            messages: [.user(MetaPrompts.analyzerInput(draft, target: target))],
                                            model: model,
                                            options: .json())
        return ResponseParsing.parseDiagnosis(raw)
    }

    /// Stage 2. Yields the accumulated text after every chunk, so a cancelled run still has a prefix.
    public func write(brief: String) -> AsyncThrowingStream<String, Error> {
        stream(system: MetaPrompts.writer(target: target), messages: [.user(brief)], model: model)
    }

    /// Stage 3. Nil means the reviewer's reply could not be parsed: not a reason to discard the prompt.
    public func verify(prompt: String) async throws -> Critique? {
        let system = MetaPrompts.critic(target: target)
        let raw = try await client.complete(system: system,
                                            messages: [.user(MetaPrompts.criticInput(prompt: prompt, draft: draft, target: target))],
                                            model: model,
                                            options: .json())
        return ResponseParsing.parseCritique(raw)
    }

    /// Stage 4. Streams like the writer, so a long repair is visible instead of a spinner.
    public func repair(prompt: String, issues: [CritiqueIssue]) -> AsyncThrowingStream<String, Error> {
        stream(system: MetaPrompts.repair,
               messages: [.user(MetaPrompts.repairInput(prompt: prompt, issues: issues, target: target,
                                                        draft: draft,
                                                        lengthTarget: target.lengthTarget))],
               model: model)
    }

    /// Stage 5. Nil on failure: tests are a bonus and must never cost the prompt.
    public func tests(prompt: String) async throws -> EvalSuite? {
        let raw = try await client.complete(system: MetaPrompts.evalSuite(target: target),
                                            messages: [.user(MetaPrompts.evalInput(prompt: prompt, target: target))],
                                            model: model,
                                            options: .json())
        return ResponseParsing.parseEvalSuite(raw)
    }

    /// Refine: a revision of the whole prompt with the conversation so far as context.
    public func revise(history: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        stream(system: MetaPrompts.writer(target: target), messages: history, model: model)
    }

    // MARK: - Streaming plumbing

    private func stream(system: String, messages: [ChatMessage], model: String) -> AsyncThrowingStream<String, Error> {
        let base = MetaPrompts.personalize(system, profile: profile)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var raw = ""
                do {
                    for try await chunk in client.stream(system: base, messages: messages, model: model) {
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
    /// Output hygiene belongs to `ResponseParsing`; kept as a named step because "finalise what
    /// the model produced" is a pipeline concept, not a parsing detail.
    public static func finalize(_ raw: String) -> String { ResponseParsing.finalize(raw) }
}
