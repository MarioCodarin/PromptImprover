import Foundation

struct UserProfile: Codable, Equatable {
    enum Expertise: String, Codable, CaseIterable, Identifiable { case beginner = "Beginner", intermediate = "Intermediate", expert = "Expert"; var id: String { rawValue } }
    enum Tone: String, Codable, CaseIterable, Identifiable { case direct = "Direct", friendly = "Friendly", formal = "Formal"; var id: String { rawValue } }
    enum Detail: String, Codable, CaseIterable, Identifiable { case concise = "Concise", balanced = "Balanced", thorough = "Thorough"; var id: String { rawValue } }

    var name = ""
    var role = ""
    var expertise: Expertise = .intermediate
    var tone: Tone = .direct
    var detail: Detail = .balanced
    var language = "Match my input"
    var defaultAgent = ""
    var customInstructions = ""
    var learnFromFeedback = true

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined().uppercased()
        return s.isEmpty ? "?" : s
    }

    static let languages = ["Match my input", "English", "Italiano", "Español", "Français", "Deutsch", "Português"]
    static let agents = ["Claude Code", "OpenCode", "Codex", "Cursor", "ChatGPT", "Claude.ai", "Custom agent loop"]
}

struct FeedbackEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var positive: Bool
    var tags: [String]
    var target: String
}

enum FeedbackTag {
    static let negative = ["Too long", "Too generic", "Missed my intent", "Too many questions", "Wrong format"]
    static let positive = ["Spot on", "Great structure", "Right length", "Good questions"]

    /// How a recurring tag turns into guidance for the model.
    static let guidance: [String: String] = [
        "Too long": "Recent prompts felt too long. Be tighter and drop sections that add little.",
        "Too generic": "Recent prompts felt generic. Be more specific to the task, with less boilerplate.",
        "Missed my intent": "Stay close to the user's literal intent. Don't broaden or reinterpret the scope.",
        "Too many questions": "Ask fewer clarifying questions. Prefer stated assumptions.",
        "Wrong format": "Pay extra attention to the deliverable format the user wants.",
        "Spot on": "The user has liked how closely prompts match their intent. Keep that fidelity.",
        "Great structure": "The user likes the sectioned structure. Keep it.",
        "Right length": "The current prompt length suits the user.",
        "Good questions": "The user finds the clarifying questions useful.",
    ]
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published var profile: UserProfile { didSet { save() } }
    @Published private(set) var feedback: [FeedbackEntry] { didSet { save() } }

    private let pKey = "profile.v1", fKey = "feedback.v1"

    init() {
        let d = UserDefaults.standard
        profile = d.data(forKey: pKey).flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) } ?? UserProfile()
        feedback = d.data(forKey: fKey).flatMap { try? JSONDecoder().decode([FeedbackEntry].self, from: $0) } ?? []
    }

    func record(positive: Bool, tags: [String], target: PromptTarget) {
        feedback.insert(FeedbackEntry(positive: positive, tags: tags, target: target.rawValue), at: 0)
        if feedback.count > 200 { feedback.removeLast(feedback.count - 200) }
    }

    func clearFeedback() { feedback = [] }

    /// Tags seen at least twice in the last 30 ratings, most frequent first.
    var learnedPreferences: [String] {
        var counts: [String: Int] = [:]
        for e in feedback.prefix(30) { for t in e.tags { counts[t, default: 0] += 1 } }
        return counts.filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .compactMap { FeedbackTag.guidance[$0.key] }
    }

    var satisfaction: Double? {
        guard !feedback.isEmpty else { return nil }
        return Double(feedback.filter(\.positive).count) / Double(feedback.count)
    }

    /// The block injected into both meta-prompts. Nil when there is nothing worth saying.
    func contextBlock() -> String? {
        let p = profile
        var lines: [String] = []
        if !p.role.isEmpty { lines.append("Role: \(p.role)") }
        lines.append("Expertise in the task domain: \(p.expertise.rawValue)")
        lines.append("Preferred tone of prompts: \(p.tone.rawValue)")
        lines.append("Preferred level of detail: \(p.detail.rawValue)")
        if p.language != "Match my input" { lines.append("Write prompts in: \(p.language)") }
        if !p.defaultAgent.isEmpty { lines.append("Usually runs prompts in: \(p.defaultAgent)") }
        let ci = p.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ci.isEmpty { lines.append("Always apply:\n\(ci)") }
        if p.learnFromFeedback, !learnedPreferences.isEmpty {
            lines.append("Learned from the user's ratings:\n" + learnedPreferences.map { "- \($0)" }.joined(separator: "\n"))
        }
        return "<user_profile>\n" + lines.joined(separator: "\n") + "\n</user_profile>"
    }

    private func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(profile) { d.set(data, forKey: pKey) }
        if let data = try? JSONEncoder().encode(feedback) { d.set(data, forKey: fKey) }
    }
}
