import SwiftUI
import PromptCore

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
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(shortName(store.selected?.selectedModel) ?? "Choose model")
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
        guard store.hasKey(e) else { return .warn }
        return e.selectedModel == nil ? .secondary : .ok
    }

    /// Menu labels ignore frame limits, so a long model id is cut here. The full id is in the menu.
    private func shortName(_ m: String?) -> String? {
        guard let m else { return nil }
        return m.count > 18 ? String(m.prefix(16)) + "…" : m
    }
}

// MARK: - Questions

struct QuestionsCard: View {
    @EnvironmentObject var vm: ImproverViewModel
    @EnvironmentObject var ui: QuickBarUI

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(vm.questions.enumerated()), id: \.element.id) { i, q in
                        QuestionRow(number: i + 1, question: binding(q.id))
                    }
                }
            }
            .frame(maxHeight: max(260, ui.maxHeight * 0.55))

            HStack(spacing: 8) {
                Button("Skip") { vm.skipQuestions() }
                    .buttonStyle(.plain).font(.ui).foregroundStyle(.secondary)
                Spacer()
                Text("new line").font(.meta).foregroundStyle(.tertiary)
                Keycap(keys: "⌥↩")
                Spacer().frame(width: 8)
                Keycap(keys: "⌘↩")
                Button("Write prompt") { vm.generate() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .card(padding: 16)
        .transition(.opacity.combined(with: .offset(y: 8)))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(number)").font(.figure).foregroundStyle(.tertiary)
                    .frame(width: 16, alignment: .leading)
                Text(question.question).font(.heading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Why the question is being asked. Without it, an interruption reads as noise.
            if !question.why.isEmpty {
                Text(question.why)
                    .font(.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            if !question.options.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(question.options, id: \.self) { opt in
                        Chip(title: opt, selected: question.answer == opt) {
                            question.answer = question.answer == opt ? "" : opt
                        }
                    }
                }
            }
            // Multi-line: a real answer is a sentence or three, not a word. It grows to eight lines
            // and then scrolls; ⌥↩ inserts a line break.
            TextField(question.options.isEmpty ? "Your answer" : "Or your own answer",
                      text: $question.answer, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.heading.weight(.regular))
                .lineLimit(3...8)
                .padding(10)
                .padding(.horizontal, 2)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08)))

            // Say what skipping means. The writer records this as an assumption, and the structural
            // check fails the prompt if the assumption is never written down.
            if !question.default.isEmpty {
                Text("If you skip: \(question.default)")
                    .font(.meta)
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
                .font(.ui)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .foregroundStyle(selected ? Color.spark : Color.primary)
                .background(Capsule().fill(selected ? Color.spark.opacity(0.14) : Color.white.opacity(0.06)))
                .overlay(Capsule().strokeBorder(selected ? Color.spark.opacity(0.6) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.feedback, value: selected)
    }
}

// MARK: - Result (compact preview)

struct ResultPreview: View {
    @EnvironmentObject var vm: ImproverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if vm.output.isEmpty {
                    Text("Writing the prompt")
                        .font(.ui).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                } else {
                    Text(vm.output)
                        .font(.figure)
                        .lineSpacing(4)
                        .lineLimit(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                }
            }
            .padding(16)
            .contentShape(Rectangle())
            .onTapGesture { if !vm.output.isEmpty { vm.expanded = true } }

            Divider().opacity(0.5)

            HStack(spacing: 8) {
                if vm.isBusy {
                    Text("\(wordCount) words").font(.figure).foregroundStyle(.tertiary)
                } else {
                    Thumbs()
                }
                Spacer()
                if let q = vm.qualityLine {
                    QualityBadge(text: q)
                }
                Button("Expand") { vm.expanded = true }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(vm.output.isEmpty)
                CopyButton()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
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
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Collapse")
                Keycap(keys: "esc")

                Text("Prompt").font(.heading).padding(.leading, 4)
                if vm.isBusy {
                    Button { vm.cancel() } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Stop")
                }
                Spacer()
                Text("\(vm.output.split(whereSeparator: \.isWhitespace).count) words · ~\(vm.output.count / 4) tokens")
                    .font(.figure).foregroundStyle(.tertiary)
                SaveButton()
                CopyButton()
            }
            .padding(.horizontal, 12).frame(height: 44)

            Divider().opacity(0.5)

            if !vm.analysis.isEmpty {
                DisclosureGroup {
                    Text(vm.analysis)
                        .font(.ui).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding(.top, 4)
                } label: {
                    Text("Diagnosis").font(.ui).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                Divider().opacity(0.5)
            }

            QualityPanel()

            ScrollView {
                // Set like a proof: mono, open leading, a wide margin.
                Text(vm.output)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.vertical, 20)
            }
            .frame(maxHeight: .infinity)

            if vm.phase == .done {
                Divider().opacity(0.5)
                HStack(spacing: 8) {
                    Thumbs()
                    Divider().frame(height: 16)
                    TextField("Refine, e.g. shorter, add a table, for Claude Code", text: $vm.refineText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.ui)
                        .lineLimit(1...4)
                        .onSubmit { vm.refine() }
                    Button("Refine") { vm.refine() }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(vm.refineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
            }
        }
        .card()
    }
}

/// Writes the prompt, and the acceptance tests beside it when there are any, to disk.
private struct SaveButton: View {
    @EnvironmentObject var vm: ImproverViewModel

    var body: some View {
        Button("Save") { save() }
            .buttonStyle(QuietButtonStyle())
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
        Button(vm.copied ? "Copied" : "Copy") { vm.copyOutput() }
        .buttonStyle(PrimaryButtonStyle())
        .help("Copy (⇧⌘C)")
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
                .font(.ui)
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(vm.rated != nil)
        .help(up ? "Good prompt" : "Needs work")
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ui.positive ? "What worked" : "What was off")
                .font(.heading)
            FlowLayout(spacing: 6) {
                ForEach(ui.positive ? FeedbackTag.positive : FeedbackTag.negative, id: \.self) { t in
                    Chip(title: t, selected: ui.tags.contains(t)) {
                        if ui.tags.contains(t) { ui.tags.remove(t) } else { ui.tags.insert(t) }
                    }
                }
            }
            HStack {
                if profiles.profile.learnFromFeedback {
                    Text("Shapes future prompts").font(.meta).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Send") {
                    vm.rate(positive: ui.positive, tags: Array(ui.tags).sorted(), profile: profiles)
                    ui.open = false
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Small pieces

struct KeyBanner: View {
    @EnvironmentObject var ui: QuickBarUI
    private func showSettings() { ui.openSettings() }
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.warn).frame(width: 6, height: 6).frame(width: 16)
            Text("Add an API key to start").font(.ui)
            Spacer()
            Button("Settings") { showSettings() }.buttonStyle(QuietButtonStyle())
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 8)
        .card(radius: 12)
    }
}

struct StatusRow: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(text).font(.ui).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .transition(.opacity)
    }
}

struct ErrorRow: View {
    @EnvironmentObject var vm: ImproverViewModel
    let message: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(Color.bad).frame(width: 6, height: 6).frame(width: 16)
            Text(message).font(.ui).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { vm.error = nil } label: { Image(systemName: "xmark").font(.meta) }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Dismiss")
        }
        .padding(12)
        .card(radius: 12)
    }
}

// MARK: - Shared styling
//
// Direction: exact, quiet, a little warm. Graphite surfaces, the logo's coral used as ink in a few
// places only (the send key, a chosen answer, the rubric figure). Four type sizes, one easing
// curve, everything on a 4pt grid.

extension Color {
    /// The one accent: the coral of the logo's spark. Deep enough for a white glyph on it (3.6:1)
    /// and for coral text on the bar surface (4.5:1).
    static let spark = Color(red: 0.80, green: 0.42, blue: 0.30)
    /// Surface of the bar and every card above it.
    static let barSurface = Color(red: 0.125, green: 0.118, blue: 0.137)
    /// Off-white from the same ramp: the primary button, with dark text on it.
    static let paper = Color(red: 0.925, green: 0.914, blue: 0.894)
    /// Semantic colours, toned down to sit inside the palette. They mean something; never decor.
    static let ok = Color(red: 0.52, green: 0.72, blue: 0.56)
    static let warn = Color(red: 0.86, green: 0.67, blue: 0.40)
    static let bad = Color(red: 0.88, green: 0.44, blue: 0.42)
}

extension Font {
    /// The four sizes. Hierarchy comes from size and the three text roles, not from weight.
    static let meta = Font.system(size: 11)           // counts, hints, "if you skip"
    static let ui = Font.system(size: 12)             // controls, body
    static let heading = Font.system(size: 13, weight: .medium)
    static let entry = Font.system(size: 15)          // the draft in the bar
    static let figure = Font.system(size: 11, design: .monospaced)
}

extension Animation {
    /// The one curve. Short for feedback, a little longer for things that enter.
    static let feedback = Animation.easeOut(duration: 0.16)
    static let enter = Animation.easeOut(duration: 0.24)
}

extension View {
    /// Dark rounded surface with a hairline edge and a soft neutral shadow: the one container
    /// style, used by the bar and every card stacked above it.
    func card(padding: CGFloat = 0, radius: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.barSurface.opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }
}

/// A shortcut shown where it applies, instead of hiding in a tooltip.
struct Keycap: View {
    let keys: String
    var body: some View {
        Text(keys)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.10)))
    }
}

/// Off-white with dark text: the one primary action in a card (Copy, Write prompt, Send).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.barSurface)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.paper))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.feedback, value: configuration.isPressed)
    }
}

/// A raised step of the surface: every secondary action (Save, Expand, Refine, Settings).
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.07)))
            .opacity(enabled ? 1 : 0.4)
            .animation(.feedback, value: configuration.isPressed)
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
