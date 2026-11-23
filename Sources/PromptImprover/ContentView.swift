import SwiftUI

// MARK: - Menu bar panel (the whole app UI)

struct PanelView: View {
    @EnvironmentObject var store: EndpointStore
    @EnvironmentObject var vm: ImproverViewModel

    private var missingKey: Bool { store.selected.map { !store.hasKey($0) } ?? true }
    private var hasResult: Bool { !vm.output.isEmpty || vm.isBusy }

    var body: some View {
        VStack(spacing: 10) {
            Header()
            if missingKey { KeyBanner() }

            if vm.expanded && hasResult {
                ExpandedResult()
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            } else {
                Composer()
                if vm.isBusy { StatusRow(text: vm.phase.label) }
                if !vm.questions.isEmpty && (vm.phase == .answering) { QuestionsCard() }
                if hasResult { ResultPreview().transition(.opacity) }
            }

            if let err = vm.error { ErrorRow(message: err) }
        }
        .padding(12)
        .frame(width: vm.expanded && hasResult ? 660 : 380)
        .frame(height: vm.expanded && hasResult ? 620 : nil)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.smooth(duration: 0.25), value: vm.phase)
        .animation(.smooth(duration: 0.25), value: vm.expanded)
        .task {
            guard !vm.didAutoFetch, let e = store.selected, store.hasKey(e) else { return }
            vm.didAutoFetch = true
            do { try await store.refreshModels(e) }
            catch { vm.reportBackground("Couldn't load models: \(error.localizedDescription)") }
        }
    }
}

// MARK: - Header

private struct Header: View {
    @EnvironmentObject var vm: ImproverViewModel
    @EnvironmentObject var profiles: ProfileStore
    @Environment(\.openSettings) private var openSettings
    private func showSettings() {
        // Accessory (menu bar) apps aren't frontmost: open first, then force-activate so Settings isn't hidden.
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        HStack(spacing: 8) {
            ModelMenu()
            Spacer()
            if vm.phase != .idle {
                Button { vm.reset() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("New prompt")
            }
            Menu {
                Button("Settings…") { showSettings() }
                    .keyboardShortcut(",")
                Button("New prompt") { vm.reset() }
                Divider()
                Button("Quit Prompt Improver") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Avatar(initials: profiles.profile.initials, size: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.system(size: 12))
    }
}

private struct ModelMenu: View {
    @EnvironmentObject var store: EndpointStore
    @EnvironmentObject var vm: ImproverViewModel

    var body: some View {
        Menu {
            ForEach(store.endpoints) { e in
                Section(e.name) {
                    if e.models.isEmpty { Text("No models yet. Fetch them in Settings.") }
                    ForEach(e.models, id: \.self) { m in
                        Button { store.select(e, model: m) } label: {
                            if e.id == store.selected?.id && m == e.selectedModel {
                                Label(m, systemImage: "checkmark")
                            } else { Text(m) }
                        }
                    }
                }
            }
            Divider()
            Button("Refresh models") {
                guard let e = store.selected else { return }
                Task {
                    do { try await store.refreshModels(e) }
                    // A background failure must not clobber a run's own error banner.
                    catch { vm.reportBackground("Couldn't load models: \(error.localizedDescription)") }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(store.selected?.selectedModel ?? "Choose model")
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(store.selected?.name ?? "")
    }
}

// MARK: - Composer

private struct Composer: View {
    @EnvironmentObject var store: EndpointStore
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var vm: ImproverViewModel

    private var canSend: Bool { !vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var greeting: String {
        let first = profiles.profile.name.split(separator: " ").first.map(String.init)
        return first.map { "Hi \($0), what should an AI do?" } ?? "What should an AI do?"
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if vm.draft.isEmpty {
                    Text(greeting)
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $vm.draft)
                    .textEditorStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 14))
            }
            .frame(height: vm.phase == .idle ? 110 : 64)
            .padding([.horizontal, .top], 10)

            HStack(spacing: 6) {
                Menu {
                    ForEach(PromptTarget.allCases) { t in
                        Button { vm.target = t } label: { Label(t.rawValue, systemImage: t.icon) }
                    }
                } label: {
                    Label(vm.target.rawValue, systemImage: vm.target.icon)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Toggle(isOn: $vm.askQuestions) {
                    Image(systemName: "questionmark.bubble")
                }
                .toggleStyle(.button)
                .help(vm.askQuestions ? "Clarifying questions on" : "Clarifying questions off")

                Menu {
                    ForEach(Rigor.allCases) { r in
                        Button { vm.rigor = r } label: {
                            if vm.rigor == r { Label(r.rawValue, systemImage: "checkmark") } else { Text(r.rawValue) }
                        }
                    }
                } label: {
                    Label(vm.rigor.rawValue, systemImage: "dial.medium")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(vm.rigor.blurb)

                Spacer()

                Button {
                    vm.isBusy ? vm.cancel() : vm.start(store: store, profile: profiles)
                } label: {
                    Image(systemName: vm.isBusy ? "stop.fill" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(canSend || vm.isBusy ? Color.accentColor : Color.secondary.opacity(0.3)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(vm.phase == .answering ? nil : KeyboardShortcut(.return, modifiers: .command))
                .disabled((!canSend && !vm.isBusy) || vm.phase == .answering)
                .help(vm.isBusy ? "Stop" : "Improve (⌘↩)")
            }
            .controlSize(.small)
            .padding(8)
        }
        .card()
    }
}

// MARK: - Questions

private struct QuestionsCard: View {
    @EnvironmentObject var vm: ImproverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(vm.questions.enumerated()), id: \.element.id) { i, q in
                        QuestionRow(number: i + 1, question: binding(q.id))
                    }
                }
            }
            .frame(maxHeight: 300)

            HStack {
                Button("Skip") { vm.skipQuestions() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("Write prompt") { vm.generate() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .controlSize(.small)
        }
        .card(padding: 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func binding(_ id: UUID) -> Binding<ClarifyingQuestion> {
        Binding(
            get: { vm.questions.first { $0.id == id } ?? ClarifyingQuestion(question: "", why: "", options: []) },
            set: { new in if let i = vm.questions.firstIndex(where: { $0.id == id }) { vm.questions[i] = new } }
        )
    }
}

private struct QuestionRow: View {
    let number: Int
    @Binding var question: ClarifyingQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                Text(question.question).font(.system(size: 12.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Why the question is being asked. Without it, an interruption reads as noise.
            if !question.why.isEmpty {
                Text(question.why)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }
            if !question.options.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(question.options, id: \.self) { opt in
                        Chip(title: opt, selected: question.answer == opt) {
                            question.answer = question.answer == opt ? "" : opt
                        }
                    }
                }
            }
            TextField("Or type an answer…", text: $question.answer)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.vertical, 5).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))

            // Say what skipping means. The writer records this as an assumption, and the structural
            // check fails the prompt if the assumption is never written down.
            if !question.default.isEmpty {
                Text("If you skip: \(question.default)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: selected)
    }
}

// MARK: - Result (compact preview)

private struct ResultPreview: View {
    @EnvironmentObject var vm: ImproverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if vm.output.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Writing your prompt…").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                } else {
                    Text(vm.output)
                        .font(.system(size: 11, design: .monospaced))
                        .lineSpacing(2)
                        .lineLimit(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                }
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture { if !vm.output.isEmpty { vm.expanded = true } }

            Divider().opacity(0.6)

            HStack(spacing: 6) {
                if vm.isBusy {
                    ProgressView().controlSize(.mini)
                    Text("\(wordCount) words").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Thumbs()
                }
                Spacer()
                if let q = vm.qualityLine {
                    QualityBadge(text: q)
                }
                CopyButton()
                Button { vm.expanded = true } label: {
                    Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .disabled(vm.output.isEmpty)
            }
            .controlSize(.small)
            .padding(8)
        }
        .card()
    }

    private var wordCount: Int { vm.output.split(whereSeparator: \.isWhitespace).count }
}

// MARK: - Result (expanded)

private struct ExpandedResult: View {
    @EnvironmentObject var vm: ImproverViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { vm.expanded = false } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.borderless)
                .help("Collapse")
                .keyboardShortcut(.escape, modifiers: [])

                Text("Prompt").font(.system(size: 13, weight: .semibold))
                if vm.isBusy {
                    ProgressView().controlSize(.mini)
                    Button { vm.cancel() } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.borderless).help("Stop")
                }
                Spacer()
                Text("\(vm.output.split(whereSeparator: \.isWhitespace).count) words · ~\(vm.output.count / 4) tok")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                SaveButton().controlSize(.small)
                CopyButton().controlSize(.small)
            }
            .padding(.horizontal, 12).frame(height: 40)

            Divider().opacity(0.6)

            if !vm.analysis.isEmpty {
                DisclosureGroup {
                    Text(vm.analysis)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding(.top, 4)
                } label: {
                    Text("Diagnosis").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider().opacity(0.6)
            }

            QualityPanel()

            ScrollView {
                Text(vm.output)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(maxHeight: .infinity)

            if vm.phase == .done {
                Divider().opacity(0.6)
                HStack(spacing: 8) {
                    Thumbs()
                    Divider().frame(height: 16)
                    TextField("Refine: \"shorter\", \"add a table\", \"for Claude Code\"…", text: $vm.refineText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit { vm.refine() }
                    Button("Refine") { vm.refine() }
                        .controlSize(.small)
                        .disabled(vm.refineText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12).frame(height: 42)
            }
        }
        .card()
    }
}

/// Writes the prompt, and the acceptance tests when there are any, to a markdown file.
private struct SaveButton: View {
    @EnvironmentObject var vm: ImproverViewModel

    var body: some View {
        Button {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "prompt.md"
            panel.allowedContentTypes = [.plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            var doc = vm.output
            if let suite = vm.evalSuite { doc += "\n\n" + suite.markdown }
            try? doc.write(to: url, atomically: true, encoding: .utf8)
        } label: {
            Label("Save", systemImage: "square.and.arrow.down")
        }
        .disabled(vm.output.isEmpty || vm.isBusy)
    }
}

private struct CopyButton: View {
    @EnvironmentObject var vm: ImproverViewModel
    var body: some View {
        Button { vm.copyOutput() } label: {
            Label(vm.copied ? "Copied" : "Copy", systemImage: vm.copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(vm.output.isEmpty || vm.isBusy)
    }
}

// MARK: - Feedback

final class FeedbackUI: ObservableObject {
    @Published var open = false
    @Published var positive = true
    @Published var tags: Set<String> = []
}

private struct Thumbs: View {
    @EnvironmentObject var vm: ImproverViewModel
    @EnvironmentObject var profiles: ProfileStore
    @StateObject private var ui = FeedbackUI()

    var body: some View {
        HStack(spacing: 2) {
            thumb(true)
            thumb(false)
        }
        .popover(isPresented: $ui.open, arrowEdge: .bottom) { picker }
    }

    private func thumb(_ up: Bool) -> some View {
        let active = vm.rated == up
        return Button {
            ui.positive = up; ui.tags = []; ui.open = true
        } label: {
            Image(systemName: up ? (active ? "hand.thumbsup.fill" : "hand.thumbsup")
                                 : (active ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                .font(.system(size: 12))
                .foregroundStyle(active ? (up ? Color.green : Color.orange) : Color.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
                .symbolEffect(.bounce, value: active)
        }
        .buttonStyle(.plain)
        .disabled(vm.rated != nil)
        .help(up ? "Good prompt" : "Needs work")
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ui.positive ? "What worked?" : "What was off?")
                .font(.system(size: 13, weight: .semibold))
            FlowLayout(spacing: 6) {
                ForEach(ui.positive ? FeedbackTag.positive : FeedbackTag.negative, id: \.self) { t in
                    Chip(title: t, selected: ui.tags.contains(t)) {
                        if ui.tags.contains(t) { ui.tags.remove(t) } else { ui.tags.insert(t) }
                    }
                }
            }
            HStack {
                if profiles.profile.learnFromFeedback {
                    Label("Shapes future prompts", systemImage: "sparkle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Send") {
                    vm.rate(positive: ui.positive, tags: Array(ui.tags).sorted(), profile: profiles)
                    ui.open = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - Small pieces

private struct KeyBanner: View {
    @Environment(\.openSettings) private var openSettings
    private func showSettings() {
        // Accessory (menu bar) apps aren't frontmost: open first, then force-activate so Settings isn't hidden.
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.gradient))
            Text("Add your API key to start").font(.system(size: 12, weight: .medium))
            Spacer()
            Button("Settings") { showSettings() }.controlSize(.small)
        }
        .card(padding: 8)
    }
}

private struct StatusRow: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .transition(.opacity)
    }
}

private struct ErrorRow: View {
    @EnvironmentObject var vm: ImproverViewModel
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            Text(message).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { vm.error = nil } label: { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .card(padding: 8)
    }
}

// MARK: - Shared styling

extension View {
    /// Flat surface with a hairline border — the one container style used everywhere.
    func card(padding: CGFloat = 0) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
    }
}

extension PromptTarget {
    var icon: String {
        switch self {
        case .agentTask: return "bolt.horizontal"
        case .systemPrompt: return "gearshape.2"
        case .chat: return "bubble.left"
        }
    }
}

/// Wrapping row layout for option chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(ProposedViewSize(width: maxW.isFinite ? maxW : nil, height: nil))
            if x > 0 && x + s.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
