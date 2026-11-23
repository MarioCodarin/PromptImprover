import SwiftUI
import AppKit

@main
struct PromptImproverApp: App {
    @StateObject private var store = EndpointStore()
    @StateObject private var vm = ImproverViewModel()
    @StateObject private var profiles = ProfileStore()

    init() {
        // Build-time and diagnostic hooks. All of these exit before any UI is created.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            IconRenderer.render(iconset: args[i + 1])
            exit(0)
        }
        if args.contains("--selftest") { exit(SelfTest.run()) }
        if let i = args.firstIndex(of: "--lint") {
            // Without a path this fell through to the GUI, so a mistyped invocation opened a
            // menu-bar app and looked like a hang instead of printing usage.
            guard i + 1 < args.count else {
                FileHandle.standardError.write(Data("usage: PromptImprover --lint <file> [--target \"Agent task\"] [--unanswered N]\n".utf8))
                exit(64)
            }
            // A mistyped target silently linted as an agent task, which is the wrong section set
            // and therefore the wrong verdict. Same rule as --rigor: name the accepted values.
            var target = PromptTarget.agentTask
            if let t = args.firstIndex(of: "--target"), t + 1 < args.count {
                guard let parsed = PromptTarget(rawValue: args[t + 1]) else {
                    let names = PromptTarget.allCases.map(\.rawValue).joined(separator: "\", \"")
                    FileHandle.standardError.write(Data("unknown target \"\(args[t + 1])\" — use one of: \"\(names)\"\n".utf8))
                    exit(64)
                }
                target = parsed
            }
            var unanswered = 0
            if let u = args.firstIndex(of: "--unanswered"), u + 1 < args.count {
                guard let n = Int(args[u + 1]), n >= 0 else {
                    FileHandle.standardError.write(Data("--unanswered needs a count, got \"\(args[u + 1])\"\n".utf8))
                    exit(64)
                }
                unanswered = n
            }
            exit(SelfTest.lintFile(args[i + 1], target: target, unanswered: unanswered))
        }
        if args.contains("--dump-prompts") { SelfTest.dumpPrompts(); exit(0) }
        if let i = args.firstIndex(of: "--vm") {
            guard let c = VMProbe.parse(Array(args[i...])) else {
                FileHandle.standardError.write(Data("usage: PromptImprover --vm <baseURL> [--key K] [--model M] [--rigor Fast|Standard|Deep]\n".utf8))
                exit(64)
            }
            // The probe drives @MainActor state, so the task must start on the main actor and the
            // runloop must keep pumping until it finishes.
            var code: Int32 = 70
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                code = await VMProbe.run(base: c.base, key: c.key, model: c.model, rigor: c.rigor)
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
            exit(code)
        }
        if let i = args.firstIndex(of: "--e2e") {
            guard let config = E2E.parse(Array(args[i...])) else {
                // The usage line listed seven of the eleven flags `E2E.parse` accepts, so a
                // mistyped run hid the four that would have fixed it: --effort, --price-in,
                // --price-out and --answer-questions.
                FileHandle.standardError.write(Data("""
                usage: PromptImprover --e2e <baseURL> [--key K] [--model M] [--format openai|anthropic] \
                [--draft TEXT] [--target \"Agent task\"] [--rigor Fast|Standard|Deep] [--answer-questions] \
                [--effort low|medium|high|none|minimal|xhigh] [--out FILE] [--price-in N] [--price-out N] \
                [--json]

                """.utf8))
                exit(64)
            }
            // No UI exists yet at this point, so pump the runloop while the async run completes.
            var code: Int32 = 70
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                code = await E2E.run(config)
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            }
            exit(code)
        }
        LoginItem.enableOnFirstLaunch()
    }

    var body: some Scene {
        // Menu bar only (LSUIElement in Info.plist hides the Dock icon).
        MenuBarExtra {
            PanelView()
                .environmentObject(store)
                .environmentObject(vm)
                .environmentObject(profiles)
        } label: {
            Image(nsImage: MenuBarIcon.image(busy: vm.isBusy))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(store).environmentObject(profiles).environmentObject(vm)
        }
    }
}

/// The logo reduced to a monochrome 18pt template glyph, so macOS tints it for light/dark menu bars.
enum MenuBarIcon {
    private static let idle = make(busy: false)
    private static let working = make(busy: true)

    static func image(busy: Bool) -> NSImage { busy ? working : idle }

    private static func make(busy: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()

            let chevron = NSBezierPath()
            chevron.lineWidth = 2
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.move(to: NSPoint(x: 2.5, y: 6.5))
            chevron.line(to: NSPoint(x: 7.5, y: 10.75))
            chevron.line(to: NSPoint(x: 2.5, y: 15))
            chevron.stroke()

            NSBezierPath(roundedRect: NSRect(x: 9.5, y: 14, width: 5.5, height: 2), xRadius: 1, yRadius: 1).fill()

            // Spark: bigger while the model is working.
            let c = NSPoint(x: 13.5, y: 5)
            let r: CGFloat = busy ? 5 : 4.2
            let spark = NSBezierPath()
            spark.move(to: NSPoint(x: c.x, y: c.y - r))
            for p in [NSPoint(x: c.x + r, y: c.y), NSPoint(x: c.x, y: c.y + r),
                      NSPoint(x: c.x - r, y: c.y), NSPoint(x: c.x, y: c.y - r)] {
                spark.curve(to: p, controlPoint1: c, controlPoint2: c)
            }
            spark.fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
