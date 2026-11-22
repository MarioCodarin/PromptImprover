import Foundation
import AppKit

@MainActor
final class ImproverViewModel: ObservableObject {
    enum Phase: Equatable { case idle, analyzing, answering, generating, done }

    @Published var draft = ""
    @Published var target: PromptTarget = .agentTask
    @Published var askQuestions = true

    @Published var phase: Phase = .idle
    @Published var analysis = ""
    @Published var questions: [ClarifyingQuestion] = []
    @Published var output = ""
    @Published var refineText = ""
    @Published var error: String?
    @Published var copied = false
    @Published var expanded = false
    var didAutoFetch = false
    @Published var rated: Bool? = nil   // nil = not rated yet for the current output

    private var client: LLMClient?
    private var model = ""
    private var profileContext: String?
    private var history: [ChatMessage] = []
    private var task: Task<Void, Never>?

    var isBusy: Bool { phase == .analyzing || phase == .generating }

    func start(store: EndpointStore, profile: ProfileStore) {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let e = store.selected else { return }
        guard let key = store.apiKey(for: e) else { error = LLMError.missingKey.errorDescription; return }
        guard let m = e.selectedModel ?? e.models.first else { error = "Pick a model first."; return }

        client = LLMClient(endpoint: e, apiKey: key)
        profileContext = profile.contextBlock()
        model = m
        error = nil; analysis = ""; questions = []; output = ""; history = []

        guard askQuestions else { generate(); return }

        phase = .analyzing
        task = Task {
            do {
                let raw = try await client!.complete(
                    system: MetaPrompts.personalize(MetaPrompts.analyzer, profile: profileContext),
                    messages: [.user(MetaPrompts.analyzerInput(draft, target: target))],
                    model: model)
                let (a, qs) = MetaPrompts.parseAnalysis(raw)
                analysis = a
                questions = qs
                if qs.isEmpty { generate() } else { phase = .answering }
            } catch { fail(error) }
        }
    }

    func generate() {
        let brief = MetaPrompts.composeBrief(draft: draft, analysis: analysis, questions: questions)
        history = [.user(brief)]
        runWriter()
    }

    func refine() {
        let instr = refineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instr.isEmpty, !output.isEmpty else { return }
        history += [.assistant(output),
                    .user("Revise the prompt: \(instr)\nReturn the full revised prompt only.")]
        refineText = ""
        runWriter()
    }

    private func runWriter() {
        guard let client else { return }
        phase = .generating
        output = ""
        rated = nil
        let system = MetaPrompts.personalize(MetaPrompts.writer(target: target), profile: profileContext)
        let msgs = history
        task = Task {
            do {
                var raw = ""
                for try await chunk in client.stream(system: system, messages: msgs, model: model) {
                    raw += chunk
                    output = MetaPrompts.stripThinking(raw)
                }
                output = MetaPrompts.unfence(MetaPrompts.stripThinking(raw))
                if output.isEmpty { throw LLMError.api("The model returned an empty response.") }
                phase = .done
            } catch { fail(error) }
        }
    }

    func cancel() {
        task?.cancel()
        phase = output.isEmpty ? .idle : .done
    }

    func reset() {
        cancel()
        draft = ""; analysis = ""; questions = []; output = ""; error = nil; phase = .idle; expanded = false
    }

    func rate(positive: Bool, tags: [String], profile: ProfileStore) {
        profile.record(positive: positive, tags: tags, target: target)
        rated = positive
    }

    func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    private func fail(_ err: Error) {
        if err is CancellationError || (err as? URLError)?.code == .cancelled { return }
        error = err.localizedDescription
        phase = output.isEmpty ? .idle : .done
    }
}
