import Foundation
import PromptCore
import AppKit

/// The UI side of the pipeline: questions, streamed text, cancel, and what stays on screen.
///
/// The stage order, budgets and repair policy live in `PromptPipeline` (PromptCore), which the
/// `--e2e` harness drives too. This type only turns its events into published state, under two
/// invariants:
/// 1. `runID` is bumped on every start/cancel, and every event handler checks it, so a cancelled
///    stream can never overwrite a newer run.
/// 2. Only linted text survives an interruption. Each `.lint` event marks the text on screen as a
///    finished prompt (`lastGood`); a stop or failure restores it, and a fragment is cleared.
@MainActor
final class ImproverViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle, analyzing, answering, generating, verifying, repairing, testing, done

        /// A model call is in flight. One list, read by the view model and the menu bar icon.
        var isBusy: Bool { [.analyzing, .generating, .verifying, .repairing, .testing].contains(self) }

        var label: String {
            switch self {
            case .idle: return ""
            case .analyzing: return "Reading your draft…"
            case .answering: return "A few questions first"
            case .generating: return "Writing the prompt…"
            case .verifying: return "Reviewing it…"
            case .repairing: return "Fixing what the check found…"
            case .testing: return "Writing acceptance tests…"
            case .done: return ""
            }
        }
    }

    @Published var draft = ""
    @Published var target: PromptTarget = .agentTask
    @Published var askQuestions = true
    @Published var rigor: Rigor = .standard { didSet { UserDefaults.standard.set(rigor.rawValue, forKey: Self.rigorKey) } }

    /// The depth and target this run was started with. The menus can change mid-run; scoring and
    /// rating must use what the run was actually built for.
    private(set) var runRigor: Rigor = .standard
    private(set) var runTarget: PromptTarget = .agentTask

    @Published var phase: Phase = .idle
    @Published var analysis = ""
    @Published var questions: [ClarifyingQuestion] = []
    @Published var output = ""
    @Published var refineText = ""
    @Published var error: String?
    @Published var copied = false
    @Published var expanded = false
    @Published var rated: Bool? = nil   // nil = not rated yet for the current output

    /// Evidence behind the prompt, shown in the quality panel.
    @Published var diagnosis: Diagnosis?
    @Published var critique: Critique?
    @Published var lint: PromptLinter.Report?
    @Published var evalSuite: EvalSuite?

    @Published var repairOutcome: RepairOutcome = .none
    /// Why a repair was discarded, for the panel. Nil when nothing was discarded.
    @Published var repairNote: String?
    /// The run ended on its time budget. The prompt on screen is complete, but later stages did not run.
    @Published var timedOut = false
    @Published var calls = 0
    @Published var elapsed: TimeInterval = 0
    @Published var tokensIn = 0
    @Published var tokensOut = 0

    var didAutoFetch = false

    enum RepairOutcome: Equatable {
        case none, applied, reverted
    }

    static let rigorKey = "improver.rigor"

    init() {
        if let s = UserDefaults.standard.string(forKey: Self.rigorKey), let r = Rigor(rawValue: s) { rigor = r }
    }

    private var pipeline: PromptPipeline?
    private var client: (any LLMTransport)?
    private var history: [ChatMessage] = []
    private var task: Task<Void, Never>?
    private var runID = 0
    /// The last finished, linted prompt and its evidence, restored if a later stage is interrupted.
    private var lastGood: (output: String, history: [ChatMessage], lint: PromptLinter.Report?, critique: Critique?)?
    private var startedAt = Date()

    var isBusy: Bool { phase.isBusy }
    /// A run owns the error banner from its first stage until it finishes, including while it
    /// waits for answers (which `isBusy` excludes by design).
    var ownsErrorBanner: Bool { phase != .idle && phase != .done }
    var canRefine: Bool { phase == .done && !output.isEmpty }

    /// One line for the panel: what the pipeline did, in numbers.
    var qualityLine: String? {
        guard let lint else { return nil }
        var parts = ["structure \(lint.score)/100"]
        if let critique {
            let n = critique.issues.count
            parts.append(n == 0 ? "review clean" : "review found \(n)")
        }
        if let suite = evalSuite, !suite.cases.isEmpty { parts.append("\(suite.cases.count) tests") }
        if timedOut { parts.append("time limit reached") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Lifecycle

    func start(store: EndpointStore, profile: ProfileStore) {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let e = store.selected else { return }
        guard store.hasKey(e), let key = store.apiKey(for: e) else { error = LLMError.missingKey.errorDescription; return }
        guard let m = e.selectedModel ?? e.models.first else { error = "Pick a model first."; return }
        begin(client: LLMClient(endpoint: e, apiKey: key), model: m, profile: profile.contextBlock())
    }

    /// Shared entry point for the UI and the headless `--vm` probe.
    func begin(client: any LLMTransport, model: String, profile: String?) {
        task?.cancel()
        runID += 1
        self.client = client
        runTarget = target
        runRigor = rigor
        pipeline = PromptPipeline(request: .init(draft: draft, target: target, rigor: rigor,
                                                 model: model, profile: profile),
                                  transport: client)
        error = nil; analysis = ""; questions = []; output = ""; history = []; lastGood = nil; expanded = false
        diagnosis = nil; critique = nil; lint = nil; evalSuite = nil; calls = 0
        repairOutcome = .none; repairNote = nil; timedOut = false
        tokensIn = 0; tokensOut = 0
        startedAt = Date(); elapsed = 0

        // `askQuestions` decides whether the run stops for answers, not whether clarify happens:
        // its defaults and findings feed the writer either way.
        guard runRigor.verifies else { compose(); return }
        clarify()
    }

    private func clarify() {
        guard let pipeline else { return }
        phase = .analyzing
        let run = runID
        task = Task {
            do {
                let d = try await pipeline.clarify()
                guard run == runID, !Task.isCancelled else { return }
                calls += 1
                diagnosis = d
                analysis = render(d)
                questions = d.questions
                if d.questions.isEmpty || !askQuestions { compose() } else { phase = .answering }
            } catch { fail(error, run: run) }
        }
    }

    func generate() {
        guard phase == .answering || phase == .analyzing else { return }
        compose()
    }

    /// Skip means skip: half-typed answers are not sent, and the writer records its own defaults.
    func skipQuestions() {
        guard phase == .answering || phase == .analyzing else { return }
        for i in questions.indices { questions[i].answer = "" }
        compose()
    }

    private func compose() {
        guard let pipeline else { return }
        task?.cancel()
        runID += 1
        let run = runID
        phase = .generating
        output = ""
        rated = nil
        let stream = pipeline.compose(diagnosis: diagnosis, questions: questions, priorCalls: calls)
        task = Task { await consume(stream, run: run) }
    }

    // MARK: - Refine

    func refine() {
        let instr = refineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instr.isEmpty, !output.isEmpty, phase == .done, let pipeline else { return }
        lastGood = (output, history, lint, critique)
        refineText = ""
        task?.cancel()
        runID += 1
        let run = runID
        let current = output
        phase = .generating
        rated = nil
        critique = nil; evalSuite = nil; repairOutcome = .none; repairNote = nil; timedOut = false
        let stream = pipeline.refine(current: current, history: history, instruction: instr, priorCalls: calls)
        task = Task { await consume(stream, run: run) }
    }

    // MARK: - Events

    private func consume(_ stream: AsyncThrowingStream<PromptPipeline.Event, Error>, run: Int) async {
        do {
            for try await event in stream {
                guard run == runID else { return }
                apply(event)
            }
        } catch { fail(error, run: run) }
    }

    private func apply(_ event: PromptPipeline.Event) {
        switch event {
        case .stage(let s):
            switch s {
            case .clarify: phase = .analyzing
            case .write: phase = .generating
            case .review: phase = .verifying
            case .repair: phase = .repairing
            case .tests: phase = .testing
            }
        case .partial(let text):
            output = text
        case .lint(let report):
            // The text on screen is now a finished, linted prompt: something a stop may restore.
            lint = report
            lastGood = (output, history, report, critique)
        case .critique(let c):
            critique = c
        case .repair(let r):
            switch r {
            case .none: repairOutcome = .none; repairNote = nil
            case .applied: repairOutcome = .applied; repairNote = nil
            case .reverted(let why): repairOutcome = .reverted; repairNote = why
            }
        case .tests(let suite):
            evalSuite = suite
        case .finished(let r):
            output = r.prompt
            lint = r.lint
            critique = r.critique
            evalSuite = r.tests
            history = r.history
            timedOut = r.endedBy == .timedOut
            calls = r.calls
            tokensIn = r.tokensIn
            tokensOut = r.tokensOut
            elapsed = Date().timeIntervalSince(startedAt)
            lastGood = nil
            phase = .done
        }
    }

    // MARK: - Commands

    func cancel() {
        // Stop means "stop working", not "throw away what you already finished": a linted prompt
        // comes back; a half-streamed fragment does not.
        task?.cancel()
        runID += 1
        if !restoreLastGood() {
            output = ""
            lint = nil
            critique = nil
            evalSuite = nil
        }
        // A stopped run still spent what it spent.
        elapsed = Date().timeIntervalSince(startedAt)
        if let usage = client?.usage {
            tokensIn = usage.inputTokens
            tokensOut = usage.outputTokens
        }
        phase = output.isEmpty ? .idle : .done
        if output.isEmpty { expanded = false }
    }

    func reset() {
        cancel()
        draft = ""; analysis = ""; questions = []; output = ""; error = nil
        phase = .idle; expanded = false; lastGood = nil; history = []
        diagnosis = nil; critique = nil; lint = nil; evalSuite = nil; calls = 0; elapsed = 0
        tokensIn = 0; tokensOut = 0; repairOutcome = .none; repairNote = nil; timedOut = false
        rated = nil; copied = false
    }

    func rate(positive: Bool, tags: [String], profile: ProfileStore) {
        // `runTarget`, not `target`: the menu can change mid-run, and a prompt written for an
        // agent task must not be filed as a chat message.
        profile.record(positive: positive, tags: tags, target: runTarget)
        rated = positive
    }

    func copyOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        flashCopied()
    }

    func copyTests() {
        guard let suite = evalSuite else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(suite.markdown, forType: .string)
        flashCopied()
    }

    /// Shows the copy confirmation for a moment, then clears it.
    ///
    /// The clear is unconditional. Guarding it on `runID` looked tidier and made the clear
    /// unreachable: `runID` moves on every start, refine, repair and cancel, so a copy taken
    /// shortly before one of those left the badge showing "Copied" for the rest of the session.
    private func flashCopied() {
        copied = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.copied = false
        }
    }

    /// Errors raised outside a run (model list refresh) must not overwrite a run's own error banner,
    /// and must not leave a stale one behind when the next run starts.
    func reportBackground(_ message: String) {
        // A background failure (a model-list refresh) must not overwrite the banner of a run that
        // is in flight or waiting for answers.
        guard !ownsErrorBanner, error == nil else { return }
        error = message
    }

    // MARK: - Helpers

    private func render(_ d: Diagnosis) -> String {
        var lines: [String] = []
        if !d.brief.isEmpty { lines.append(d.brief) }
        if !d.findings.isEmpty {
            lines.append("")
            for f in d.findings {
                let quote = f.quote.isEmpty ? "" : " — \u{201C}\(f.quote.prefix(70))\u{201D}"
                lines.append("• \(f.code) \(f.title)\(quote)")
            }
        }
        if !d.assumptions.isEmpty {
            lines.append("")
            lines.append("Defaults it would assume: " + d.assumptions.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    /// Puts the last finished prompt back. Returns whether anything was restored, so the caller
    /// can tell "a good prompt came back" from "the stream died mid-write".
    @discardableResult
    private func restoreLastGood() -> Bool {
        guard let good = lastGood else { return false }
        output = good.output
        history = good.history
        lint = good.lint
        critique = good.critique
        lastGood = nil
        return true
    }

    private func fail(_ err: Error, run: Int) {
        guard run == runID else { return }
        if err is CancellationError || (err as? URLError)?.code == .cancelled { return }
        error = err.localizedDescription
        // Restore first, then decide. A restored prompt is a real result and must survive; only
        // text that arrived during a failed stream is a fragment. Testing the phase wiped the
        // prompt that had just been put back, because refine and repair are exactly the phases
        // that set `lastGood`.
        let restored = restoreLastGood()
        if !restored {
            // A stream that died mid-write leaves a sentence, not a prompt. Keeping it would put
            // unvalidated text behind an enabled Copy button with no structure score.
            output = ""
            lint = nil
            critique = nil
            evalSuite = nil
        }
        phase = output.isEmpty ? .idle : .done
    }
}
