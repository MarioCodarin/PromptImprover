import Foundation

/// Headless driver for `ImproverViewModel`, used by `--vm`.
///
/// `--e2e` exercises `PromptEngine` stage by stage, which means it covers the pipeline and none
/// of the state machine. Every `runID` guard, `cancel`, `refine` and error path lived outside any
/// test — and a `fail()` that destroyed the prompt it had just restored passed a green 11/11 gate.
/// This probe drives the same view model the window drives, against the same mock, and asserts the
/// invariants that only exist there.
enum VMProbe {

    enum Case: String, CaseIterable {
        case restore = "restore"
        case cancel = "cancel"
        case rigor = "rigor"
    }

    static func parse(_ args: [String]) -> (base: String, key: String, model: String, rigor: Rigor)? {
        var base = "", key = "k", model = "mock"
        var rigor = Rigor.fast
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
                if i + 1 < args.count { rigor = Rigor(rawValue: args[i + 1]) ?? .fast; i += 1 }
            default: break
            }
            i += 1
        }
        guard !base.isEmpty else { return nil }
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

        // ---- 3. The depth is fixed when the run starts. ------------------------------------
        // A fresh client: the one above is poisoned, and a dead transport would fail this run for
        // a reason that has nothing to do with what is being tested.
        let liveClient = LLMClient(endpoint: endpoint, apiKey: key)
        let vm3 = ImproverViewModel()
        vm3.draft = "make me a landing page for a coffee subscription"
        vm3.rigor = .fast
        vm3.begin(client: liveClient, model: model, profile: nil)
        vm3.rigor = .deep           // flipped mid-flight, as the menu allows
        let ran = await settle(vm3, until: { $0.phase == .done || $0.error != nil }, timeout: 40)
        check("a mid-run depth change does not reshape the pipeline",
              ran && vm3.calls == 1, "\(vm3.calls) calls, expected 1 for Fast")

        print(failures == 0 ? "vm probe: all green" : "vm probe: \(failures) failing")
        return failures == 0 ? 0 : 1
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
