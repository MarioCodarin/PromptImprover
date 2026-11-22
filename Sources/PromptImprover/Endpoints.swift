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

    init(id: UUID = UUID(), name: String, baseURL: String, format: APIFormat = .openAI,
         models: [String] = [], selectedModel: String? = nil, reasoningEffort: String? = nil) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.format = format
        self.models = models; self.selectedModel = selectedModel; self.reasoningEffort = reasoningEffort
    }

    /// Tolerant decoding: missing or unknown fields fall back to defaults instead of failing the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Endpoint"
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        format = (try? c.decodeIfPresent(APIFormat.self, forKey: .format)) ?? .openAI
        models = (try? c.decodeIfPresent([String].self, forKey: .models)) ?? []
        selectedModel = try? c.decodeIfPresent(String.self, forKey: .selectedModel)
        reasoningEffort = try? c.decodeIfPresent(String.self, forKey: .reasoningEffort)
    }

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
    /// Which endpoints have a key, so views don't hit the Keychain on every render.
    @Published private(set) var keyed: Set<UUID> = []

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
        keyed = Set(endpoints.map(\.id).filter { Keychain.get($0.uuidString) != nil })
    }

    func hasKey(_ e: Endpoint) -> Bool { keyed.contains(e.id) }

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
        keyed.remove(e.id)
        if endpoints.isEmpty { _ = add(.refuseless) }   // fresh id, so no stale key can attach to it
        if selectedID == e.id || !endpoints.contains(where: { $0.id == selectedID }) { selectedID = endpoints.first?.id }
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
        guard endpoints.contains(where: { $0.id == e.id }) else { return }   // never resurrect a removed endpoint's key
        if trimmed.isEmpty {
            Keychain.delete(e.id.uuidString); keyed.remove(e.id)
        } else {
            Keychain.set(trimmed, for: e.id.uuidString); keyed.insert(e.id)
        }
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
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
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
