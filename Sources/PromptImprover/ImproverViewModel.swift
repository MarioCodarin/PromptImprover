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
    @Published var rated: Bool? = nil   // nil = not rated yet for the current output
    var didAutoFetch = false

    private var client: LLMClient?
    private var model = ""
    private var profileContext: String?
    private var history: [ChatMessage] = []
    private var task: Task<Void, Never>?

    /// Bumped on every start/cancel. A task only writes state while its own run is still current,
    /// so a cancelled stream (which ends quietly, without throwing) can never overwrite newer state.
    private var runID = 0
    /// Last good result, restored if a refine fails or is stopped.
    private var lastGood: (output: String, history: [ChatMessage])?

    var isBusy: Bool { phase == .analyzing || phase == .generating }

    func start(store: EndpointStore, profile: ProfileStore) {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let e = store.selected else { return }
        guard store.hasKey(e), let key = store.apiKey(for: e) else { error = LLMError.missingKey.errorDescription; return }
        guard let m = e.selectedModel ?? e.models.first else { error = "Pick a model first."; return }

        task?.cancel()
        runID += 1
        let client = LLMClient(endpoint: e, apiKey: key)
        self.client = client
        profileContext = profile.contextBlock()
        model = m
        error = nil; analysis = ""; questions = []; output = ""; history = []; lastGood = nil; expanded = false

        guard askQuestions else { generate(); return }

        phase = .analyzing
        let run = runID
        let system = MetaPrompts.personalize(MetaPrompts.analyzer, profile: profileContext)
        let input = MetaPrompts.analyzerInput(draft, target: target)
        task = Task {
            do {
                let raw = try await client.complete(system: system, messages: [.user(input)], model: m)
                guard run == runID, !Task.isCancelled else { return }
                let (a, qs) = MetaPrompts.parseAnalysis(raw)
                analysis = a
                questions = qs
                if qs.isEmpty { generate() } else { phase = .answering }
            } catch { fail(error, run: run) }
        }
    }

    func generate() {
        let brief = MetaPrompts.composeBrief(draft: draft, analysis: analysis, questions: questions)
        history = [.user(brief)]
        lastGood = nil
        runWriter()
    }

    /// Skip means skip: half-typed answers are not sent.
    func skipQuestions() {
        for i in questions.indices { questions[i].answer = "" }
        generate()
    }

    func refine() {
        let instr = refineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instr.isEmpty, !output.isEmpty, phase == .done else { return }
        lastGood = (output, history)
        history += [.assistant(output),
                    .user("Revise the prompt: \(instr)\nReturn the full revised prompt only.")]
        refineText = ""
        runWriter()
    }

    private func runWriter() {
        guard let client else { return }
        task?.cancel()
        runID += 1
        let run = runID
        phase = .generating
        output = ""
        rated = nil
        let system = MetaPrompts.personalize(MetaPrompts.writer(target: target), profile: profileContext)
        let msgs = history, model = model
        task = Task {
            do {
                var raw = ""
                for try await chunk in client.stream(system: system, messages: msgs, model: model) {
                    guard run == runID else { return }
                    raw += chunk
                    output = MetaPrompts.stripThinking(raw)
                }
                guard run == runID, !Task.isCancelled else { return }
                let final = MetaPrompts.unfence(MetaPrompts.stripThinking(raw))
                if final.isEmpty { throw LLMError.api("The model returned an empty response.") }
                output = final
                lastGood = nil
                phase = .done
            } catch { fail(error, run: run) }
        }
    }

    func cancel() {
        task?.cancel()
        runID += 1
        restoreAfterInterruptedRefine()
        phase = output.isEmpty ? .idle : .done
        if output.isEmpty { expanded = false }
    }

    func reset() {
        cancel()
        draft = ""; analysis = ""; questions = []; output = ""; error = nil
        phase = .idle; expanded = false; lastGood = nil; history = []
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

    private func restoreAfterInterruptedRefine() {
        if let good = lastGood {
            output = good.output
            history = good.history
            lastGood = nil
        }
    }

    private func fail(_ err: Error, run: Int) {
        guard run == runID else { return }
        if err is CancellationError || (err as? URLError)?.code == .cancelled { return }
        error = err.localizedDescription
        restoreAfterInterruptedRefine()
        phase = output.isEmpty ? .idle : .done
    }
}
