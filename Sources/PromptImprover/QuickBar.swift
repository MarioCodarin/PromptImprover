import SwiftUI
import PromptCore
import AppKit
import Combine

/// UI state shared between the AppKit controller and the SwiftUI bar.
@MainActor
final class QuickBarUI: ObservableObject {
    /// Bumped every time the bar is shown, so the text field takes focus.
    @Published var focusToken = 0
    /// Usable height of the screen the bar is on. Cards cap themselves against it.
    @Published var maxHeight: CGFloat = 700
    var hide: () -> Void = {}
    var openSettings: () -> Void = {}
}

/// A borderless floating panel that keeps its bottom edge and horizontal centre fixed, so when
/// SwiftUI grows the content (questions, results) the panel grows upward out of the bar.
final class QuickBarPanel: NSPanel {
    /// Bottom-centre point the panel is pinned to, in screen coordinates.
    var anchor: NSPoint?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(pinned(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(pinned(frameRect), display: displayFlag, animate: animateFlag)
    }

    private func pinned(_ r: NSRect) -> NSRect {
        guard let a = anchor else { return r }
        return NSRect(x: (a.x - r.width / 2).rounded(), y: a.y, width: r.width, height: r.height)
    }
}

/// Owns the menu bar icon, the floating bar above the Dock, and the Settings window.
@MainActor
final class QuickBarController: NSObject {
    /// Transparent margin around the content so the SwiftUI shadow is not clipped by the window.
    static let shadowMargin: CGFloat = 24

    private let store: EndpointStore
    private let vm: ImproverViewModel
    private let profiles: ProfileStore
    private let ui = QuickBarUI()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var panel: QuickBarPanel!
    private var settingsWindow: NSWindow?
    private var bag = Set<AnyCancellable>()
    private var escMonitor: Any?

    init(store: EndpointStore, vm: ImproverViewModel, profiles: ProfileStore) {
        self.store = store
        self.vm = vm
        self.profiles = profiles
        super.init()
        ui.hide = { [weak self] in self?.hide() }
        ui.openSettings = { [weak self] in self?.showSettings() }
        makeStatusItem()
        makePanel()
        installEscape()
    }

    // MARK: Status item

    private func makeStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.image(busy: false)
        button.target = self
        button.action = #selector(statusItemClicked)
        vm.$phase
            .map(\.isBusy)   // the new value: `vm.isBusy` would still read the old one here
            .removeDuplicates()
            .sink { [weak button] busy in button?.image = MenuBarIcon.image(busy: busy) }
            .store(in: &bag)
    }

    @objc private func statusItemClicked() {
        // A bar left up by a running job but no longer focused is brought back, not hidden.
        panel.isVisible && panel.isKeyWindow ? hide() : show()
    }

    // MARK: Panel

    private func makePanel() {
        let root = QuickBarView()
            .environmentObject(store)
            .environmentObject(vm)
            .environmentObject(profiles)
            .environmentObject(ui)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = .preferredContentSize

        let p = QuickBarPanel(contentRect: NSRect(x: 0, y: 0, width: 688, height: 104),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered, defer: false)
        p.contentViewController = host
        // SwiftUI's forced dark scheme does not reach AppKit-drawn popovers and menus; the window
        // appearance does, so the feedback popover is not white-on-light in Light mode.
        p.appearance = NSAppearance(named: .darkAqua)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false               // the SwiftUI shadow follows the rounded shape; the window's would not
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        panel = p

        // Any of our windows, not just the bar: after the feedback popover or Settings took focus,
        // a click into another app resigns *that* window, and the bar must still get the chance
        // to hide.
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        place(on: NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)
        panel.makeKeyAndOrderFront(nil)
        ui.focusToken &+= 1
    }

    /// Pins the bar just above the Dock of `screen`. visibleFrame already excludes the Dock (and
    /// the menu bar), whichever edge the Dock is on or whether it is hidden.
    private func place(on screen: NSScreen?) {
        guard let vf = screen?.visibleFrame else { return }
        panel.anchor = NSPoint(x: vf.midX, y: vf.minY + 10 - Self.shadowMargin)
        ui.maxHeight = vf.height - 40
        panel.setFrame(panel.frame, display: false)   // re-pin to the new anchor
    }

    /// A display unplugged, a resolution change or the Dock moved: re-pin an open bar so it is
    /// not left floating off-screen at the old position.
    @objc private func screensChanged() {
        guard panel.isVisible else { return }
        place(on: panel.screen ?? NSScreen.main)
    }

    func hide() {
        panel.orderOut(nil)
    }

    @objc private func windowResignedKey() {
        // One hop: during the notification, the window taking over is not key yet.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
            if self.shouldHideOnResign() { self.hide() }
        }
    }

    /// Click-away policy: whether the bar should disappear now that it has lost keyboard focus.
    /// Called one runloop hop after the panel lost key, and only while it is still on screen.
    ///
    /// Available inputs:
    /// - `NSApp.keyWindow` — non-nil when another of *our* windows took focus (feedback popover,
    ///   Save panel, Settings). nil when the user clicked into another app or the desktop.
    /// - `vm.isBusy` — a run is streaming (analyzing / generating / verifying / repairing / testing).
    /// - `vm.phase` — `.answering` while clarifying questions wait; `.done` once a result exists.
    /// - `vm.draft`, `vm.output`, `vm.expanded` — what the user would lose sight of.
    private func shouldHideOnResign() -> Bool {
        // Another of our own windows took focus (popover, Save panel, Settings): hiding would pull
        // the bar out from under the thing the user just opened.
        if NSApp.keyWindow != nil { return false }
        // Work in flight, or questions waiting, stay visible. Everything else (draft, result) is
        // kept in the view model and is there again on the next click of the icon.
        return !vm.isBusy && vm.phase != .answering
    }

    /// Esc collapses the expanded result first, then hides the bar.
    private func installEscape() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.panel else { return event }
            // Mid-composition (Japanese, Chinese, Korean input), Esc cancels the composition.
            if (self.panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
            if self.vm.expanded { self.vm.expanded = false } else { self.hide() }
            return nil
        }
    }

    // MARK: Settings

    /// `openSettings` only works from inside a SwiftUI scene, and this bar is an AppKit panel, so
    /// Settings gets its own window.
    func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView()
                .environmentObject(store)
                .environmentObject(profiles)
                .environmentObject(vm))
            let w = NSWindow(contentViewController: host)
            w.title = "Prompt Improver Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
