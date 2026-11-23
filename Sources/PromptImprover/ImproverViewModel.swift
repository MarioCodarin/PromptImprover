import Foundation
import AppKit

/// Drives the five-stage pipeline: diagnose → write → lint → verify → repair (+ tests).
///
/// The view model owns interaction (questions, partial text, cancel); `PromptEngine` owns the model
/// calls. Two invariants keep the state honest:
/// 1. `runID` is bumped on every start/cancel, and every stage checks it before writing state, so a
///    cancelled stream (which ends quietly, without throwing) can never overwrite a newer run.
/// 2. The writer's output is never trusted on its own: the deterministic linter and the critic both
///    have to pass, and a failing verdict triggers a repair pass — with the original kept if the
///    repair scores worse structurally than what it replaced.
@MainActor
final class ImproverViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle, analyzing, answering, generating, verifying, repairing, testing, done

        var label: String {
            switch self {
            case .idle: return ""
            case .analyzing: return "Reading your draft…"
            case .answering: return "A few questions first"
            case .generating: return "Writing the prompt…"
            case .verifying: return "Checking it against the rubric…"
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

    /// The depth this run was started with. Changing the menu mid-run must not reshape a pipeline
    /// that is already in flight; the live value only affects the next run.
    private(set) var runRigor: Rigor = .standard

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
    /// The target this run was started with. Scoring must use this, not `target`, which the menu
    /// can change mid-run: a prompt written for an agent task must not be judged as a chat message.
    private(set) var runTarget: PromptTarget = .agentTask

    /// Whether a repair pass was applied or attempted-and-reverted. The panel has to say which,
    /// because a "repair" verdict with no note reads as a repair that is still coming.
    @Published var repairOutcome: RepairOutcome = .none
    @Published var calls = 0
    @Published var elapsed: TimeInterval = 0
    @Published var tokensIn = 0
    @Published var tokensOut = 0

    var didAutoFetch = false

    enum RepairOutcome: Equatable {
        case none, applied, reverted
    }

    /// Why a repair was discarded, for the panel. Nil when nothing was discarded.
    @Published var repairNote: String?
    /// Whether the verify currently running is the re-check after a repair. The two are the same
    /// phase but their verdicts mean different things, and `cancel` has to tell them apart.
    private var verifyingRepaired = false

    static let rigorKey = "improver.rigor"

    init() {
        if let s = UserDefaults.standard.string(forKey: Self.rigorKey), let r = Rigor(rawValue: s) { rigor = r }
    }

    private var engine: PromptEngine?
    private var client: LLMClient?
    private var history: [ChatMessage] = []
    private var task: Task<Void, Never>?

    /// Bumped on every start/cancel. A task only writes state while its own run is still current.
    private var runID = 0
    /// Last good result, restored if a refine fails or is stopped.
    /// The result to put back if a refine or repair dies. Carries the scores, because restoring
    /// the text without them would blank the panel on a prompt that had already been verified.
    private var lastGood: (output: String, history: [ChatMessage], lint: PromptLinter.Report?, critique: Critique?)?
    private var startedAt = Date()

    var isBusy: Bool { [.analyzing, .generating, .verifying, .repairing, .testing].contains(phase) }
    /// A run owns the error banner from the moment it starts until it finishes, including while it
    /// waits for the user to answer questions. `isBusy` excludes `.answering` by design, so it is
    /// the wrong test for "may a background task write here".
    var ownsErrorBanner: Bool {
        // A run owns the banner from its first stage until it finishes. `task != nil` used to be
        // part of this and never went false, because `task` is never cleared — so after one run a
        // failed model refresh was silently dropped for the rest of the session.
        phase != .idle && phase != .done
    }
    var canRefine: Bool { phase == .done && !output.isEmpty }

    /// One line for the panel: what the pipeline did, in numbers.
    var qualityLine: String? {
        guard let lint else { return nil }
        var parts: [String] = []
        if let critique { parts.append("rubric \(critique.total(for: runTarget))/100") }
        parts.append("structure \(lint.score)/100")
        if let suite = evalSuite, !suite.cases.isEmpty { parts.append("\(suite.cases.count) tests") }
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

    /// Shared entry point for the UI and the headless `--e2e` runner.
    func begin(client: LLMClient, model: String, profile: String?) {
        task?.cancel()
        runID += 1
        self.client = client
        runTarget = target
        runRigor = rigor
        engine = PromptEngine(client: client, model: model, target: target,
                              profile: profile, draft: draft)
        error = nil; analysis = ""; questions = []; output = ""; history = []; lastGood = nil; expanded = false
        diagnosis = nil; critique = nil; lint = nil; evalSuite = nil; calls = 0
        repairOutcome = .none
        tokensIn = 0; tokensOut = 0
        startedAt = Date(); elapsed = 0

        // `askQuestions` controls whether the run stops for answers, not whether stage 1 happens:
        // the analyzer's output is the writer's defect list, task type and risk, and losing it made
        // the same draft produce a different prompt depending on one checkbox.
        guard runRigor.verifies else { runWriter(); return }
        analyze()
    }

    /// Stage 1. Cheap, and it decides both the questions and the writer's defect list.
    private func analyze() {
        guard let engine else { return }
        phase = .analyzing
        let run = runID

        task = Task {
            do {
                let d = try await engine.diagnose()
                guard run == runID, !Task.isCancelled else { return }
                calls += 1
                diagnosis = d
                analysis = render(d)
                questions = d.questions
                if d.questions.isEmpty || !askQuestions { runWriter() } else { phase = .answering }
            } catch { fail(error, run: run) }
        }
    }

    func generate() {
        guard phase == .answering || phase == .analyzing else { return }
        runWriter()
    }

    /// Skip means skip: half-typed answers are not sent, and the writer records its own defaults.
    func skipQuestions() {
        guard phase == .answering || phase == .analyzing else { return }
        for i in questions.indices { questions[i].answer = "" }
        runWriter()
    }

    /// Stage 2. Streams, so the panel fills as the prompt is written.
    private func runWriter() {
        guard let engine else { return }
        task?.cancel()
        runID += 1
        let run = runID
        phase = .generating
        output = ""
        rated = nil

        let brief = MetaPrompts.composeBrief(draft: draft, diagnosis: diagnosis ?? Diagnosis(), questions: questions)
        history = [.user(brief)]

        task = Task {
            do {
                var last = ""
                for try await partial in engine.write(brief: brief) {
                    guard run == runID else { return }
                    last = partial
                    output = partial
                }
                guard run == runID, !Task.isCancelled else { return }
                calls += 1
                let final = PromptEngine.finalize(last)
                guard !final.isEmpty else { throw LLMError.api("The model returned an empty response.") }
                output = final
                afterWrite(run: run)
            } catch { fail(error, run: run) }
        }
    }

    /// Lint, then decide whether the model-level check is worth its call.
    private func afterWrite(run: Int) {
        guard run == runID else { return }
        lint = PromptLinter.lint(output, target: runTarget, unansweredQuestions: unansweredCount(), draft: draft)
        // The text is final at this point, so it is now something a later failure can restore.
        // Without this, a verify that threw left nothing to restore and `fail` blanked a finished,
        // already-linted prompt — while an *unparseable* verify reply kept it. One broken stage,
        // two outcomes, decided by which way it broke.
        lastGood = (output, history, lint, critique)
        guard runRigor.verifies else { finish(run: run); return }
        verify(run: run)
    }

    /// Stage 3. An independent reviewer scores the prompt against the same rubric the writer was given.
    private func verify(run: Int) {
        guard let engine else { return }
        verifyingRepaired = false
        phase = .verifying
        // Captured before the Task, like `reverify` already does. Reading `output` inside the task
        // body reads it after the current MainActor turn yields, so a cancel or a newer run in
        // between was observed — and the stale task then spent a real call on the wrong text.
        let prompt = output

        task = Task {
            do {
                let c = try await engine.verify(prompt: prompt)
                guard run == runID, !Task.isCancelled else { return }
                calls += 1
                // An unparseable reply is not a verdict, but it is not an exemption either: with
                // the critique dropped entirely the deterministic gate stopped existing, so one
                // stray brace in the critic's prose switched off repair for the whole run. An
                // empty critique says nothing, which leaves the linter's blockers and majors as
                // the only issues — exactly the case the gate exists for.
                let parsed = c ?? Critique()
                critique = c
                // Repair is driven by what the critic found *and* what the gate found. They measure
                // different things, and only the gate is deterministic: a prompt the linter rejects
                // must not ship because the critic said "ship".
                let issues = RepairGuard.issues(critique: parsed, lint: lint)
                if issues.isEmpty { nextAfterVerify(run: run) } else { repair(issues) }
            } catch { fail(error, run: run) }
        }
    }

    private func nextAfterVerify(run: Int) {
        guard run == runID else { return }
        if runRigor.writesTests { writeTests(run: run) } else { finish(run: run) }
    }

    /// Stage 4. Only the issues the critic could quote, and only when one is worth fixing.
    private func repair(_ issues: [CritiqueIssue]) {
        guard let engine else { return }
        task?.cancel()
        runID += 1
        let run = runID
        phase = .repairing
        let before = output
        output = ""
        lastGood = (before, history, lint, critique)

        task = Task {
            do {
                var last = ""
                for try await partial in engine.repair(prompt: before, issues: issues) {
                    guard run == runID else { return }
                    last = partial
                    output = partial
                }
                guard run == runID, !Task.isCancelled else { return }
                calls += 1
                let revised = PromptEngine.finalize(last)
                // Judged on what changed, not on the weighted score: a repair that closes a
                // contradiction the linter cannot see must survive a minor it introduces.
                let beforeReport = PromptLinter.lint(before, target: runTarget,
                                                     unansweredQuestions: unansweredCount(), draft: draft)
                let afterReport = PromptLinter.lint(revised, target: runTarget,
                                                    unansweredQuestions: unansweredCount(), draft: draft)
                let verdict = RepairGuard.judge(before: beforeReport, after: afterReport, revised: revised)
                if let why = verdict.note {
                    output = before
                    lint = beforeReport
                    repairOutcome = .reverted
                    repairNote = why
                    lastGood = nil
                    nextAfterVerify(run: run)
                } else {
                    repairOutcome = .applied
                    repairNote = nil
                    output = revised
                    lint = afterReport
                    lastGood = nil
                    // The critique on screen describes the pre-repair prompt. Re-score the shipped one,
                    // once, so the number in the panel is a claim about what the user actually copies.
                    reverify(run: run)
                }
            } catch { fail(error, run: run) }
        }
    }

    /// One bounded re-check after a repair. No second repair pass: the loop has to end somewhere.
    private func reverify(run: Int) {
        guard let engine else { nextAfterVerify(run: run); return }
        verifyingRepaired = true
        phase = .verifying
        let repaired = output

        task = Task {
            do {
                let c = try await engine.verify(prompt: repaired)
                guard run == runID, !Task.isCancelled else { return }
                calls += 1
                // The re-check scores `repaired`. If it produced no critique, or the text moved on
                // under it, there is no score for what is on screen — the previous critique
                // described the pre-repair text and must not survive.
                critique = output == repaired ? c : nil
                nextAfterVerify(run: run)
            } catch {
                // Losing the re-check is not losing the prompt: keep the repaired text, drop the stale score.
                guard run == runID else { return }
                critique = nil
                nextAfterVerify(run: run)
            }
        }
    }

    /// Stage 5 (deep only). Tests the user can run before trusting the prompt.
    private func writeTests(run: Int) {
        guard let engine else { finish(run: run); return }
        phase = .testing
        // Captured before the Task, for the same reason `verify` captures it.
        let prompt = output

        task = Task {
            do {
                let suite = try await engine.tests(prompt: prompt)
                guard run == runID, !Task.isCancelled else { return }
                calls += 1
                evalSuite = suite
                finish(run: run)
            } catch {
                // Tests are a bonus. Losing them must not lose the prompt.
                guard run == runID else { return }
                evalSuite = nil
                finish(run: run)
            }
        }
    }

    private func finish(run: Int) {
        // The invariant belongs to the write, not to the discipline of nine call sites.
        guard run == runID else { return }
        lastGood = nil
        elapsed = Date().timeIntervalSince(startedAt)
        if let usage = client?.usage {
            tokensIn = usage.inputTokens
            tokensOut = usage.outputTokens
        }
        phase = .done
    }

    // MARK: - Refine

    func refine() {
        let instr = refineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instr.isEmpty, !output.isEmpty, phase == .done, let engine else { return }
        lastGood = (output, history, lint, critique)
        history += [.assistant(output), .user(MetaPrompts.refineInstruction(instr))]
        refineText = ""
        task?.cancel()
        runID += 1
        let run = runID
        phase = .generating
        output = ""
        rated = nil

        let msgs = history
        task = Task {
            do {
                var last = ""
                for try await partial in engine.revise(history: msgs) {
                    guard run == runID else { return }
                    last = partial
                    output = partial
                }
                guard run == runID, !Task.isCancelled else { return }
                calls += 1
                let final = PromptEngine.finalize(last)
                guard !final.isEmpty else { throw LLMError.api("The model returned an empty response.") }
                output = final
                lint = PromptLinter.lint(final, target: runTarget, unansweredQuestions: unansweredCount(), draft: draft)
                critique = nil
                evalSuite = nil
                repairOutcome = .none
                finish(run: run)
            } catch { fail(error, run: run) }
        }
    }

    // MARK: - Commands

    func cancel() {
        // Stop means "stop working", not "throw away what you already finished". `verifying` and
        // `testing` run *after* the text is final and linted, so cancelling there must keep it —
        // this used to blank a complete prompt because `lastGood` is only set by refine and repair,
        // so the user lost a finished result to a button labelled Stop.
        let stoppingPhase = phase
        let textIsFinal = phase == .verifying || phase == .testing
        task?.cancel()
        runID += 1
        // Same rule as `fail`: a restored prompt is a result, a half-streamed fragment is not.
        // Without this, stopping mid-write left a sentence behind an enabled Copy button with no
        // structure score, which reads as a finished prompt.
        let restored = restoreAfterInterruptedRefine()
        // The verdicts describe the text. When the text goes, they go with it — a panel showing
        // "structure 40/100" over an empty box is a claim about nothing.
        if !restored && !textIsFinal {
            output = ""
            lint = nil
            critique = nil
            evalSuite = nil
        }
        // Stopping inside a re-check is the case `reverify` itself already handles: the critique in
        // hand scores the *pre-repair* text, and the re-score never lands because `runID` moved on.
        // Keeping it showed "Rubric 20/100 — Below the bar: …" over a prompt that had just been
        // repaired. The same rule as `reverify`: there is no score for what is on screen.
        //
        // Only the critique goes. `repairOutcome` and `repairNote` describe `output` — the repaired
        // text, which is still on screen and still copyable — so clearing them deleted the only
        // explanation of why the prompt reads the way it does, while keeping the prompt itself.
        if stoppingPhase == .verifying, verifyingRepaired {
            critique = nil
        }
        // A stopped run still spent what it spent. `finish` is the only other writer of these, so
        // cancelling after two completed calls reported "2 model calls · 0.0s · 0 in / 0 out" —
        // two calls that demonstrably cost money, shown as free.
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
        tokensIn = 0; tokensOut = 0; repairOutcome = .none; rated = nil; copied = false
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

    private func unansweredCount() -> Int {
        questions.filter { $0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

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

    /// Puts the pre-refine result back. Returns whether anything was restored, so the caller can
    /// tell "a good prompt came back" from "the stream died mid-write" — the two need opposite
    /// treatment, and conflating them destroyed the user's prompt.
    @discardableResult
    private func restoreAfterInterruptedRefine() -> Bool {
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
        let restored = restoreAfterInterruptedRefine()
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
