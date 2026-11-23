import SwiftUI

// MARK: - Model menu

struct ModelMenu: View {
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
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(store.selected?.selectedModel ?? "Choose model")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 110)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(store.selected?.name ?? "")
    }

    /// The dot is a status light, so it has to have more than one state. It was unconditionally
    /// green: the panel said "ready" with no key stored and no model picked.
    var statusColor: Color {
        guard let e = store.selected else { return .secondary }
        guard store.hasKey(e) else { return .orange }
        return e.selectedModel == nil ? .secondary : .green
    }
}

// MARK: - Questions

struct QuestionsCard: View {
    @EnvironmentObject var vm: ImproverViewModel
    @EnvironmentObject var ui: QuickBarUI

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(vm.questions.enumerated()), id: \.element.id) { i, q in
                        QuestionRow(number: i + 1, question: binding(q.id))
                    }
                }
            }
            .frame(maxHeight: max(260, ui.maxHeight * 0.55))

            HStack {
                Button("Skip") { vm.skipQuestions() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("Write prompt") { vm.generate() }
                    .buttonStyle(.borderedProminent)
                    .help("Write prompt (⌘↩)")
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .controlSize(.small)
        }
        .card(padding: 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
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
                Text(question.question).font(.system(size: 13, weight: .medium))
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
            // Multi-line: a real answer is a sentence or three, not a word. It grows to eight lines
            // and then scrolls; ⌥↩ inserts a line break.
            TextField(question.options.isEmpty ? "Type your answer…" : "Or type your own answer…",
                      text: $question.answer, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(3...8)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08)))

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
                .background(Capsule().fill(selected ? Color.spark : Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: selected)
    }
}

// MARK: - Result (compact preview)

struct ResultPreview: View {
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

struct ExpandedResult: View {
    @EnvironmentObject var vm: ImproverViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { vm.expanded = false } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.borderless)
                .help("Collapse (Esc)")

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
                    TextField("Refine: \"shorter\", \"add a table\", \"for Claude Code\"…", text: $vm.refineText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .lineLimit(1...4)
                        .onSubmit { vm.refine() }
                    Button("Refine") { vm.refine() }
                        .controlSize(.small)
                        .disabled(vm.refineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .card()
    }
}

/// Writes the prompt, and the acceptance tests beside it when there are any, to disk.
private struct SaveButton: View {
    @EnvironmentObject var vm: ImproverViewModel

    var body: some View {
        Button { save() } label: {
            Label("Save", systemImage: "square.and.arrow.down")
        }
        .disabled(vm.output.isEmpty || vm.isBusy)
    }

    /// Two files, not one. A prompt with a test suite appended cannot be pasted into a system slot,
    /// which is the only thing most users do with it — `--e2e --out` writes them apart for the same
    /// reason, and this used to append, so the app and the harness produced different artefacts
    /// from the same run.
    private func save() {
        // The bar is a non-activating panel, so the app may not be active: without this the
        // Save panel opens unfocused and typing goes to the previous app.
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "prompt.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try vm.output.write(to: url, atomically: true, encoding: .utf8)
            if let suite = vm.evalSuite, !suite.cases.isEmpty {
                let tests = url.deletingPathExtension().appendingPathExtension("tests.md")
                try suite.markdown.write(to: tests, atomically: true, encoding: .utf8)
            }
        } catch {
            // A silent failure here is a prompt the user believes is on disk and is not.
            vm.error = "Could not save: \(error.localizedDescription)"
        }
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

struct KeyBanner: View {
    @EnvironmentObject var ui: QuickBarUI
    private func showSettings() { ui.openSettings() }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.spark.gradient))
            Text("Add your API key to start").font(.system(size: 12, weight: .medium))
            Spacer()
            Button("Settings") { showSettings() }.controlSize(.small)
        }
        .card(padding: 8)
    }
}

struct StatusRow: View {
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

struct ErrorRow: View {
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

extension Color {
    /// The one accent: the coral of the logo's spark.
    static let spark = Color(red: 0.85, green: 0.47, blue: 0.34)
    /// Surface of the bar and every card above it.
    static let barSurface = Color(red: 0.125, green: 0.118, blue: 0.137)
}

extension View {
    /// Dark rounded surface with a hairline edge and a soft shadow: the one container style, used
    /// by the bar and every card stacked above it.
    func card(padding: CGFloat = 0, radius: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.barSurface.opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09)))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
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
