import Foundation
import Security

enum APIFormat: String, Codable, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    var id: String { rawValue }
}

struct Endpoint: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var baseURL: String
    var format: APIFormat = .openAI
    var models: [String] = []
    var selectedModel: String?
    /// nil = don't send. Otherwise sent as `reasoning_effort` (OpenAI format only).
    var reasoningEffort: String?

    static let refuseless = Endpoint(
        name: "Refuseless",
        baseURL: "https://api.refuseless.com/v1",
        format: .openAI,
        models: ["glm-5.3-abliterated", "glm-5.3-flash-abliterated", "kimi-k3.1-pro",
                 "deepseek-v4.1-flash-fast", "minimax-m3.1-flash"],
        selectedModel: "glm-5.3-abliterated"
    )

    static let presets: [Endpoint] = [
        .refuseless,
        Endpoint(name: "OpenAI", baseURL: "https://api.openai.com/v1"),
        Endpoint(name: "Anthropic", baseURL: "https://api.anthropic.com/v1", format: .anthropic),
        Endpoint(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1"),
        Endpoint(name: "Ollama (local)", baseURL: "http://localhost:11434/v1"),
    ]
}

@MainActor
final class EndpointStore: ObservableObject {
    @Published var endpoints: [Endpoint] { didSet { save() } }
    @Published var selectedID: UUID? { didSet { save() } }

    private let defaultsKey = "endpoints.v1"
    private let selectedKey = "endpoints.selected.v1"

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: defaultsKey),
           let list = try? JSONDecoder().decode([Endpoint].self, from: data), !list.isEmpty {
            endpoints = list
        } else {
            endpoints = [.refuseless]
        }
        selectedID = d.string(forKey: selectedKey).flatMap(UUID.init) ?? endpoints.first?.id
    }

    var selected: Endpoint? {
        endpoints.first { $0.id == selectedID } ?? endpoints.first
    }

    func update(_ e: Endpoint) {
        if let i = endpoints.firstIndex(where: { $0.id == e.id }) { endpoints[i] = e }
    }

    func add(_ preset: Endpoint) -> Endpoint {
        var e = preset
        e.id = UUID()
        endpoints.append(e)
        return e
    }

    func remove(_ e: Endpoint) {
        endpoints.removeAll { $0.id == e.id }
        Keychain.delete(e.id.uuidString)
        if selectedID == e.id { selectedID = endpoints.first?.id }
        if endpoints.isEmpty { endpoints = [.refuseless]; selectedID = endpoints[0].id }
    }

    func select(_ e: Endpoint, model: String) {
        var c = e
        c.selectedModel = model
        update(c)
        selectedID = e.id
    }

    /// Fetches /models, stores them, keeps the current pick if it still exists.
    @discardableResult
    func refreshModels(_ e: Endpoint) async throws -> Endpoint {
        guard let key = apiKey(for: e) else { throw LLMError.missingKey }
        let models = try await LLMClient(endpoint: e, apiKey: key).listModels()
        var c = endpoints.first { $0.id == e.id } ?? e
        if !models.isEmpty {
            c.models = models
            if c.selectedModel.map({ !models.contains($0) }) ?? true { c.selectedModel = models.first }
            update(c)
        }
        return c
    }

    func apiKey(for e: Endpoint) -> String? { Keychain.get(e.id.uuidString) }
    func setAPIKey(_ key: String, for e: Endpoint) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(e.id.uuidString) } else { Keychain.set(trimmed, for: e.id.uuidString) }
        objectWillChange.send()
    }

    private func save() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(endpoints) { d.set(data, forKey: defaultsKey) }
        d.set(selectedID?.uuidString, forKey: selectedKey)
    }
}

/// Minimal Keychain wrapper — API keys never touch UserDefaults.
enum Keychain {
    private static let service = "local.PromptImprover.apikeys"

    static func set(_ value: String, for account: String) {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
