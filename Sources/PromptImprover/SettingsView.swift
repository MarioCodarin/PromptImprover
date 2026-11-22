import SwiftUI

// Plain ObservableObjects instead of @State: the Command Line Tools SDK lacks the SwiftUI macro plugin.
final class SettingsUI: ObservableObject { @Published var editingID: UUID? }

final class EditorModel: ObservableObject {
    @Published var endpoint: Endpoint
    @Published var key = ""
    @Published var reveal = false
    @Published var status: (ok: Bool, text: String)?
    @Published var loading = false
    init(_ e: Endpoint) { endpoint = e }
}

struct SettingsView: View {
    @AppStorage("settings.tab") private var tab = "profile"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            ProfileSettings()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }.tag("profile")
            EndpointsSettings()
                .tabItem { Label("Endpoints", systemImage: "key") }.tag("endpoints")
            FeedbackSettings()
                .tabItem { Label("Feedback", systemImage: "hand.thumbsup") }.tag("feedback")
        }
        .frame(width: 700, height: 540)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @StateObject private var login = LoginItem()

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    LogoMark(size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prompt Improver").font(.system(size: 16, weight: .semibold))
                        Text("Lives in your menu bar. Click the icon to open it.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Startup") {
                Toggle("Open at login", isOn: Binding(get: { login.isEnabled || login.needsApproval },
                                                      set: { login.set($0) }))
                if login.needsApproval {
                    HStack {
                        Label("macOS needs your approval in Login Items.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") { login.openSystemSettings() }.controlSize(.small)
                    }
                }
                if let err = login.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Button("Quit Prompt Improver", role: .destructive) { NSApp.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
    }
}

// MARK: - Profile

private struct ProfileSettings: View {
    @EnvironmentObject var profiles: ProfileStore

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Avatar(initials: profiles.profile.initials, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $profiles.profile.name, prompt: Text("Your name"))
                            .textFieldStyle(.plain)
                            .font(.system(size: 20, weight: .semibold))
                        TextField("", text: $profiles.profile.role, prompt: Text("What you do, e.g. product designer, student, founder"))
                            .textFieldStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Stays on this Mac. It's added to the instructions so prompts fit you, and questions you've already answered here get skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Style") {
                Picker("Expertise", selection: $profiles.profile.expertise) {
                    ForEach(UserProfile.Expertise.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Tone", selection: $profiles.profile.tone) {
                    ForEach(UserProfile.Tone.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Detail", selection: $profiles.profile.detail) {
                    ForEach(UserProfile.Detail.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Picker("Prompt language", selection: $profiles.profile.language) {
                    ForEach(UserProfile.languages, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    TextField("Usual agent / app", text: $profiles.profile.defaultAgent, prompt: Text("e.g. Claude Code"))
                    Menu {
                        ForEach(UserProfile.agents, id: \.self) { a in Button(a) { profiles.profile.defaultAgent = a } }
                    } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }

            Section {
                TextEditor(text: $profiles.profile.customInstructions)
                    .font(.system(size: 13))
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
            } header: {
                Text("Always include")
            } footer: {
                Text("Rules for every prompt, e.g. \"cite sources\", \"output in Markdown tables\", \"assume EU context\".")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Learn from my ratings", isOn: $profiles.profile.learnFromFeedback)
                DisclosureGroup("What the model sees") {
                    Text(profiles.contextBlock() ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct Avatar: View {
    let initials: String
    var size: CGFloat = 24
    var body: some View {
        Group {
            if initials == "?" { Image(systemName: "person.fill") } else { Text(initials) }
        }
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.66, blue: 0.3), Color(red: 1, green: 0.4, blue: 0.32)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
    }
}

// MARK: - Feedback

private struct FeedbackSettings: View {
    @EnvironmentObject var profiles: ProfileStore

    var body: some View {
        Form {
            Section {
                HStack(spacing: 24) {
                    Stat(value: "\(profiles.feedback.count)", label: "Ratings")
                    Stat(value: profiles.satisfaction.map { "\(Int($0 * 100))%" } ?? "—", label: "Liked")
                    Stat(value: "\(profiles.learnedPreferences.count)", label: "Learned")
                    Spacer()
                    LogoMark(size: 44)
                }
                .padding(.vertical, 6)
            }

            Section("Learned preferences") {
                if profiles.learnedPreferences.isEmpty {
                    Text("Rate a few prompts with 👍 or 👎. When a tag shows up twice, it becomes a preference.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(profiles.learnedPreferences, id: \.self) { p in
                        Label(p, systemImage: "sparkle").font(.callout)
                    }
                }
            }

            Section("Recent") {
                if profiles.feedback.isEmpty {
                    Text("No ratings yet").foregroundStyle(.secondary)
                }
                ForEach(profiles.feedback.prefix(12)) { e in
                    HStack {
                        Image(systemName: e.positive ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                            .foregroundStyle(e.positive ? Color.green : Color.orange)
                        Text(e.tags.isEmpty ? "No tags" : e.tags.joined(separator: " · ")).font(.callout)
                        Spacer()
                        Text(e.date, format: .relative(presentation: .named))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !profiles.feedback.isEmpty {
                    Button("Clear all ratings", role: .destructive) { profiles.clearFeedback() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct Stat: View {
    let value: String, label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Endpoints

private struct EndpointsSettings: View {
    @EnvironmentObject var store: EndpointStore
    @StateObject private var ui = SettingsUI()

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Divider()
            if let e = store.endpoints.first(where: { $0.id == ui.editingID }) {
                EndpointEditor(model: EditorModel(e)).id(e.id)
            } else {
                Text("Select an endpoint").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { ui.editingID = ui.editingID ?? store.selectedID }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $ui.editingID) {
                ForEach(store.endpoints) { e in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(store.apiKey(for: e) == nil ? Color.orange : Color.green)
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.name).font(.system(size: 13))
                            Text(URL(string: e.baseURL)?.host ?? e.baseURL)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if e.id == store.selectedID {
                            Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(e.id))
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 2) {
                Menu {
                    ForEach(Endpoint.presets, id: \.name) { p in
                        Button(p.name) { ui.editingID = store.add(p).id }
                    }
                    Divider()
                    Button("Custom…") { ui.editingID = store.add(Endpoint(name: "Custom", baseURL: "https://")).id }
                } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

                Button {
                    if let e = store.endpoints.first(where: { $0.id == ui.editingID }) { store.remove(e) }
                    ui.editingID = store.endpoints.first?.id
                } label: { Image(systemName: "minus").frame(width: 22, height: 22) }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(6)
        }
    }
}

private struct EndpointEditor: View {
    @EnvironmentObject var store: EndpointStore
    @StateObject var model: EditorModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 6) {
                    Group {
                        if model.reveal {
                            TextField("API key", text: $model.key, prompt: Text("Paste your key"))
                        } else {
                            SecureField("API key", text: $model.key, prompt: Text("Paste your key"))
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { Task { await saveAndTest() } }

                    Button { model.reveal.toggle() } label: {
                        Image(systemName: model.reveal ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(model.reveal ? "Hide" : "Show")
                }

                HStack {
                    if let s = model.status {
                        Label(s.text, systemImage: s.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(s.ok ? Color.green : Color.red)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    } else {
                        Label("Stored in your macOS Keychain", systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.loading ? "Testing…" : "Save & Test") { Task { await saveAndTest() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.loading)
                }
            } header: {
                Text("API key")
            } footer: {
                if model.endpoint.baseURL.contains("refuseless") {
                    Text("Refuseless keys start with abl_. One key works for both OpenAI and Anthropic formats.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Connection") {
                TextField("Name", text: $model.endpoint.name)
                TextField("Base URL", text: $model.endpoint.baseURL)
                    .font(.system(.body, design: .monospaced))
                Picker("Format", selection: $model.endpoint.format) {
                    ForEach(APIFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Model") {
                Picker("Default model", selection: $model.endpoint.selectedModel) {
                    if model.endpoint.models.isEmpty { Text("Test the key to load models").tag(String?.none) }
                    ForEach(model.endpoint.models, id: \.self) { Text($0).tag(Optional($0)) }
                }
                Picker("Reasoning effort", selection: $model.endpoint.reasoningEffort) {
                    Text("Model default").tag(String?.none)
                    ForEach(["off", "low", "high", "max"], id: \.self) { Text($0.capitalized).tag(Optional($0)) }
                }
                .disabled(model.endpoint.format == .anthropic)
            }

            Section {
                Button(store.selectedID == model.endpoint.id ? "Active endpoint" : "Use this endpoint") {
                    save(); store.selectedID = model.endpoint.id
                }
                .disabled(store.selectedID == model.endpoint.id)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.key = store.apiKey(for: model.endpoint) ?? "" }
        .onDisappear { save() }
    }

    private func save() {
        store.update(model.endpoint)
        store.setAPIKey(model.key, for: model.endpoint)
    }

    private func saveAndTest() async {
        save()
        guard !model.key.trimmingCharacters(in: .whitespaces).isEmpty else {
            model.status = (false, "Enter an API key first."); return
        }
        model.loading = true; defer { model.loading = false }
        do {
            model.endpoint = try await store.refreshModels(model.endpoint)
            model.status = (true, "Connected · \(model.endpoint.models.count) models")
        } catch {
            model.status = (false, error.localizedDescription)
        }
    }
}
