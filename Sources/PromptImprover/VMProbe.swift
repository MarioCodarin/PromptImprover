import Foundation

/// Headless driver for `ImproverViewModel`, used by `--vm`.
///
/// `--e2e` exercises `PromptEngine` stage by stage, which means it covers the pipeline and none
/// of the state machine. Every `runID` guard, `cancel`, `refine` and error path lived outside any
/// test — and a `fail()` that destroyed the prompt it had just restored passed a green 11/11 gate.
/// This probe drives the same view model the window drives, against the same mock, and asserts the
/// invariants that only exist there.
enum VMProbe {

    static func parse(_ args: [String]) -> (base: String, key: String, model: String, rigor: Rigor)? {
        var base = "", key = "k", model = "mock"
        var rigor = Rigor.fast
        var badRigor = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--vm":
                if i + 1 < args.count { base = args[i + 1]; i += 1 }
            case "--key":
                if i + 1 < args.count { key = args[i + 1]; i += 1 }
            case "--model":
                if i + 1 < args.count { model = args[i + 1]; i += 1 }
            case "--rigor":
                if i + 1 < args.count {
                    // `?? .fast` here meant a lower-case or mistyped depth ran a one-call pipeline
                    // and the probe then asserted against it. An unrecognised value is now an
                    // error: it must not silently buy the cheap pipeline.
                    guard let r = Rigor.parse(args[i + 1]) else {
                        FileHandle.standardError.write(Data(
                            "unknown rigor \(args[i + 1]) — use one of: \(Rigor.allCases.map(\.rawValue).joined(separator: ", "))\n".utf8))
                        badRigor = true; i += 1; continue
                    }
                    rigor = r; i += 1
                }
            default: break
            }
            i += 1
        }
        guard !base.isEmpty, !badRigor else { return nil }
        return (base, key, model, rigor)
    }

    @MainActor
    static func run(base: String, key: String, model: String, rigor: Rigor) async -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "  ok    \(name)" : "  FAIL  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        let endpoint = Endpoint(name: "vm", baseURL: base, format: .openAI,
                                models: [model], selectedModel: model)
        let client = LLMClient(endpoint: endpoint, apiKey: key)

        // ---- 1. A completed run, then a refine that dies: the prompt must survive. ----------
        let vm = ImproverViewModel()
        vm.draft = "make me a landing page for a coffee subscription"
        // There is no user here, so stage 1 must not park the run in `.answering`. Without this
        // a Standard run waits for an answer that never comes and every assertion times out.
        vm.askQuestions = false
        vm.rigor = rigor
        vm.begin(client: client, model: model, profile: nil)
        let done = await settle(vm, until: { $0.phase == .done || $0.error != nil }, timeout: 40)
        check("a run reaches .done", done && vm.error == nil, vm.error ?? "timed out")
        let good = vm.output
        let goodLint = vm.lint
        check("the run produced a prompt", !good.isEmpty, "\(good.count) chars")
        check("the run produced a lint score", goodLint != nil)

        // Kill the transport underneath the view model. Every retry will fail.
        client.poison.kill()

        vm.refineText = "make it shorter"
        vm.refine()
        let died = await settle(vm, until: { $0.error != nil || $0.phase == .done }, timeout: 40)
        check("the refine reports a failure", died && vm.error != nil, vm.error ?? "no error surfaced")
        // The invariant: a failed refine restores the prompt it replaced, and does not then wipe it.
        check("a failed refine keeps the previous prompt", vm.output == good,
              "output is \(vm.output.count) chars, expected \(good.count)")
        check("a failed refine keeps its structure score", vm.lint?.score == goodLint?.score,
              "lint \(vm.lint.map { "\($0.score)" } ?? "nil")")
        check("a failed refine leaves a copyable result", !vm.output.isEmpty)

        // ---- 2. Cancel mid-write must not ship a fragment as a finished prompt. ------------
        let vm2 = ImproverViewModel()
        vm2.draft = "make me a landing page for a coffee subscription"
        // There is no user here, so stage 1 must not park the run in `.answering`. Without this
        // a Standard run waits for an answer that never comes and every assertion times out.
        vm2.askQuestions = false
        vm2.rigor = .fast
        vm2.begin(client: client, model: model, profile: nil)
        // Let a little text arrive, then stop. A poisoned client fails before the first byte, so
        // this path is reached by cancelling a live stream.
        let gotBytes = await settle(vm2, until: { !$0.output.isEmpty || $0.error != nil }, timeout: 40)
        vm2.cancel()
        let settled = await settle(vm2, until: { !$0.isBusy }, timeout: 5)
        check("cancel settles", settled || !vm2.isBusy)
        if gotBytes, vm2.error == nil {
            check("a cancelled first run ships no fragment",
                  vm2.output.isEmpty || vm2.lint != nil,
                  "\(vm2.output.count) chars, lint \(vm2.lint == nil ? "nil" : "set")")
        }

        // ---- 3. Cancelling a verify must not throw away a finished prompt. ----------------
        //
        // `verifying` and `testing` run *after* the text is final and linted, but `lastGood` was
        // only ever populated by refine and repair — so Stop during "Checking it against the
        // rubric…" ran `if !restored { output = "" }` and blanked a complete result. A button
        // labelled Stop deleted the work the user was waiting for.
        //
        // Driven against `/slow/`, because a loopback mock answers a verify in under a
        // millisecond and the phase is never observable.
        let slowClient = LLMClient(endpoint: Endpoint(name: "slow", baseURL: Self.mode("slow", of: base),
                                                      format: .openAI, models: [model],
                                                      selectedModel: model),
                                   apiKey: key)
        let vm4 = ImproverViewModel()
        vm4.draft = "make me a landing page for a coffee subscription"
        // There is no user here, so stage 1 must not park the run in `.answering`. Without this
        // a Standard run waits for an answer that never comes and every assertion times out.
        vm4.askQuestions = false
        vm4.rigor = .standard
        vm4.begin(client: slowClient, model: model, profile: nil)
        let reachedVerify = await settle(vm4, until: { $0.phase == .verifying || $0.error != nil },
                                         timeout: 40)
        let finalText = vm4.output
        let finalLint = vm4.lint
        if reachedVerify, vm4.error == nil, !finalText.isEmpty {
            vm4.cancel()
            _ = await settle(vm4, until: { !$0.isBusy }, timeout: 5)
            check("stopping a verify keeps the finished prompt", vm4.output == finalText,
                  "output is \(vm4.output.count) chars, expected \(finalText.count)")
            check("stopping a verify keeps its structure score", vm4.lint?.score == finalLint?.score,
                  "lint \(vm4.lint.map { "\($0.score)" } ?? "nil")")
            check("stopping a verify leaves a copyable result", !vm4.output.isEmpty)
            // Two calls that demonstrably cost tokens were reported as free, because `finish` is
            // the only other writer of these and cancel never ran it.
            check("stopping a verify still reports what it spent",
                  vm4.elapsed > 0 && vm4.tokensIn > 0,
                  "\(vm4.elapsed)s, \(vm4.tokensIn) in")
        } else {
            check("a Standard run reaches .verifying", false, vm4.error ?? "timed out")
        }

        // ---- 3b. Stopping a *re-verify* must drop the verdict it never replaced. ------------
        //
        // `reverify` already knows there is no score for what is on screen when the re-check is
        // lost, but `cancel` did not apply the same rule: the critique in hand scores the
        // pre-repair text, and the panel rendered "Rubric 20/100 — Below the bar …" plus "One
        // repair pass was applied. What is listed above survived it." over a prompt that had just
        // re-scored 94/100. Asserted separately because the phase is the same as a first verify.
        let vm5 = ImproverViewModel()
        vm5.draft = "make me a landing page for a coffee subscription"
        vm5.askQuestions = false
        vm5.rigor = .standard
        vm5.begin(client: LLMClient(endpoint: Endpoint(name: "slow2",
                                                       baseURL: Self.mode("slow", of: base),
                                                       format: .openAI, models: [model],
                                                       selectedModel: model),
                                    apiKey: key),
                  model: model, profile: nil)
        // Wait for the re-check: a repair has been applied and the phase is verifying again.
        let reachedReverify = await settle(
            vm5,
            until: { $0.phase == .verifying && $0.repairOutcome == .applied || $0.error != nil },
            timeout: 60)
        if reachedReverify, vm5.error == nil {
            vm5.cancel()
            _ = await settle(vm5, until: { !$0.isBusy }, timeout: 5)
            check("stopping a re-verify drops the pre-repair verdict", vm5.critique == nil,
                  "critique still \(vm5.critique == nil ? "nil" : "set")")
            // The outcome describes the repaired text, which is still on screen, so it stays. It
            // is the only explanation of why the prompt reads the way it does.
            check("stopping a re-verify keeps the repair outcome it earned",
                  vm5.repairOutcome == .applied,
                  "outcome \(vm5.repairOutcome)")
            check("stopping a re-verify keeps the repaired text", !vm5.output.isEmpty,
                  "\(vm5.output.count) chars")
        } else {
            check("a repair reaches a re-verify", false, vm5.error ?? "timed out")
        }

        // ---- 4. The depth is fixed when the run starts. ------------------------------------
        // A fresh client: the one above is poisoned, and a dead transport would fail this run for
        // a reason that has nothing to do with what is being tested.
        let liveClient = LLMClient(endpoint: endpoint, apiKey: key)
        let vm3 = ImproverViewModel()
        vm3.draft = "make me a landing page for a coffee subscription"
        // There is no user here, so stage 1 must not park the run in `.answering`. Without this
        // a Standard run waits for an answer that never comes and every assertion times out.
        vm3.askQuestions = false
        vm3.rigor = .fast
        vm3.begin(client: liveClient, model: model, profile: nil)
        vm3.rigor = .deep           // flipped mid-flight, as the menu allows
        let ran = await settle(vm3, until: { $0.phase == .done || $0.error != nil }, timeout: 40)
        check("a mid-run depth change does not reshape the pipeline",
              ran && vm3.calls == 1, "\(vm3.calls) calls, expected 1 for Fast")

        print(failures == 0 ? "vm probe: all green" : "vm probe: \(failures) failing")
        return failures == 0 ? 0 : 1    }

    /// Rewrites a mock base URL to select one of its failure modes.
    ///
    /// The mock reads the mode from the *first* path segment, so it goes before the version:
    /// `http://host/v1` becomes `http://host/slow/v1`, not `http://host/v1/slow`.
    static func mode(_ mode: String, of base: String) -> String {
        guard let r = base.range(of: "/v1", options: .backwards) else { return base }
        return base.replacingCharacters(in: r, with: "/\(mode)/v1")
    }

    /// Polls the view model until `stop` holds. The pipeline is driven by real Tasks, so there is
    /// nothing to await; this yields to the MainActor rather than sleeping on it.
    @MainActor
    private static func settle(_ vm: ImproverViewModel,
                               until stop: (ImproverViewModel) -> Bool,
                               timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if stop(vm) { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return stop(vm)
    }
}
