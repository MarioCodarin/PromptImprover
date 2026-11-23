import SwiftUI
import PromptCore

// MARK: - Root: cards stacked on top of the bar

/// Everything the floating panel shows. The bar is always the bottom row; questions, progress and
/// the result appear above it, and the panel (pinned at its bottom edge) grows upward to fit.
struct QuickBarView: View {
    @EnvironmentObject var store: EndpointStore
    @EnvironmentObject var vm: ImproverViewModel
    @EnvironmentObject var ui: QuickBarUI

    private var missingKey: Bool { store.selected.map { !store.hasKey($0) } ?? true }
    private var hasResult: Bool { !vm.output.isEmpty || vm.isBusy }
    private var showExpanded: Bool { vm.expanded && hasResult }

    var body: some View {
        VStack(spacing: 8) {
            if let err = vm.error { ErrorRow(message: err) }
            if missingKey { KeyBanner() }

            if showExpanded {
                ExpandedResult()
                    // Leaves room for the bar (up to 3 lines here), banners and the shadow margin.
                    .frame(height: max(280, min(680, ui.maxHeight - 260)))
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            } else {
                if !vm.questions.isEmpty && vm.phase == .answering { QuestionsCard() }
                if hasResult { ResultPreview().transition(.opacity) }
            }
            if vm.isBusy { StatusRow(text: vm.phase.label) }

            PromptBar()
        }
        .frame(width: showExpanded ? 760 : 640)
        .padding(QuickBarController.shadowMargin)
        .fixedSize(horizontal: false, vertical: true)
        .tint(.spark)
        .environment(\.colorScheme, .dark)
        .animation(.enter, value: vm.phase)
        .animation(.enter, value: vm.expanded)
        .task {
            guard !vm.didAutoFetch, let e = store.selected, store.hasKey(e) else { return }
            vm.didAutoFetch = true
            do { try await store.refreshModels(e) }
            catch { vm.reportBackground("Couldn't load models: \(error.localizedDescription)") }
        }
    }
}

// MARK: - The bar

struct PromptBar: View {
    @EnvironmentObject var store: EndpointStore
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var vm: ImproverViewModel
    @EnvironmentObject var ui: QuickBarUI
    @FocusState private var focused: Bool

    private var canSend: Bool { !vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard canSend, !vm.isBusy, vm.phase != .answering else { return }
        vm.start(store: store, profile: profiles)
    }

    /// ↩ in the field. After a run the draft is still there and the field is focused on every
    /// open, so a bare ↩ must not silently re-run and wipe the finished prompt: re-running is the
    /// deliberate ⌘↩ / send button, or New prompt first.
    private func submit() {
        guard vm.phase != .done else { return }
        send()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AppMenu()

            // ↩ sends, ⌥↩ breaks the line; the field grows to eight lines, then scrolls.
            TextField("Describe the task", text: $vm.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.entry)
                // Shorter while the full result is open, so the stack still fits a small screen.
                .lineLimit(1...(vm.expanded ? 3 : 8))
                .focused($focused)
                .onSubmit(submit)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                if vm.phase != .idle && !vm.isBusy {
                    Button { vm.reset(); focused = true } label: {
                        Image(systemName: "square.and.pencil").frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("New prompt")
                }
                ModelMenu()
                TargetMenu()
                OptionsMenu()
            }
            .font(.ui)
            .tint(.secondary)   // the menus are quiet; only the send button carries the accent

            // The key that will act, shown where it acts. After a result only ⌘↩ re-runs.
            if canSend && !vm.isBusy && vm.phase != .answering {
                Keycap(keys: vm.phase == .done ? "⌘↩" : "↩")
                    .transition(.opacity)
            }

            SendButton(canSend: canSend, action: {
                vm.isBusy ? vm.cancel() : send()
            })
        }
        .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 12)
        .frame(minHeight: 56)
        .animation(.feedback, value: canSend)
        .card(radius: 18)
        .onAppear { focused = true }
        .onChange(of: ui.focusToken) { focused = true }
    }
}

private struct SendButton: View {
    @EnvironmentObject var vm: ImproverViewModel
    let canSend: Bool
    let action: () -> Void

    private var live: Bool { (canSend && vm.phase != .answering) || vm.isBusy }

    var body: some View {
        Button(action: action) {
            Image(systemName: vm.isBusy ? "stop.fill" : "arrow.up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(live ? 1 : 0.4))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(live ? Color.spark : Color.white.opacity(0.08)))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .animation(.feedback, value: live)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(vm.phase == .answering ? nil : KeyboardShortcut(.return, modifiers: .command))
        .disabled(!live)
        .help(vm.isBusy ? "Stop" : "Improve")
    }
}

/// The app's own `>_` mark on the left of the bar: Settings, New prompt, Hide, Quit.
private struct AppMenu: View {
    @EnvironmentObject var vm: ImproverViewModel
    @EnvironmentObject var ui: QuickBarUI

    var body: some View {
        Menu {
            Button("Settings…") { ui.openSettings() }
                .keyboardShortcut(",")
            Button("New prompt") { vm.reset() }
            Button("Hide") { ui.hide() }
            Divider()
            Button("Quit Prompt Improver") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(nsImage: PromptGlyph.image)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Prompt Improver")
    }
}

/// Which kind of prompt to write: agent task, system prompt, chat message.
private struct TargetMenu: View {
    @EnvironmentObject var vm: ImproverViewModel

    var body: some View {
        Menu {
            Picker("Write for", selection: $vm.target) {
                ForEach(PromptTarget.allCases) { t in
                    Label(t.rawValue, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(vm.target.rawValue).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("What the prompt is for")
    }
}

/// Depth and clarifying questions: settings that change a run but rarely change between runs.
private struct OptionsMenu: View {
    @EnvironmentObject var vm: ImproverViewModel

    var body: some View {
        Menu {
            Picker("Depth", selection: $vm.rigor) {
                ForEach(Rigor.allCases) { r in Text(r.rawValue).tag(r) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Ask clarifying questions", isOn: $vm.askQuestions)
        } label: {
            Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(vm.rigor.rawValue): \(vm.rigor.blurb) · Questions \(vm.askQuestions ? "on" : "off")")
    }
}

/// The chevron and cursor from the logo, drawn in the accent: the bar's mark. An NSImage rather
/// than SwiftUI shapes, because a borderless menu's label renders images reliably and views not.
enum PromptGlyph {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            NSColor(Color.spark).set()
            let chevron = NSBezierPath()
            chevron.lineWidth = 2
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.move(to: NSPoint(x: 4, y: 5))
            chevron.line(to: NSPoint(x: 9.5, y: 10))
            chevron.line(to: NSPoint(x: 4, y: 15))
            chevron.stroke()
            NSBezierPath(roundedRect: NSRect(x: 11, y: 13.5, width: 6, height: 2), xRadius: 1, yRadius: 1).fill()
            return true
        }
        img.isTemplate = false
        return img
    }()
}
