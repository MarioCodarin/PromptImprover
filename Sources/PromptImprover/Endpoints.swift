import Foundation
import Security
import PromptCore

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
        setKeyed(e.id, false)
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

    /// Stores or clears the key. Returns whether the Keychain now holds what was asked for.
    ///
    /// The caller marks the endpoint keyed from this result. It used to insert into `keyed`
    /// unconditionally, so a Keychain refusal left the UI claiming a key that no request could
    /// read, and the failure surfaced much later as "add your API key" on a screen that said one
    /// was saved.
    @discardableResult
    func setAPIKey(_ key: String, for e: Endpoint) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoints.contains(where: { $0.id == e.id }) else { return false }   // never resurrect a removed endpoint's key
        if trimmed.isEmpty {
            Keychain.delete(e.id.uuidString)
            setKeyed(e.id, false)
            return true
        }
        guard Keychain.set(trimmed, for: e.id.uuidString) else { return false }
        setKeyed(e.id, true)
        return true
    }

    /// Publishes only when membership actually changes. The key field commits on every keystroke,
    /// and a no-op `insert` still fires `objectWillChange` for the whole store — forty characters
    /// of typing used to invalidate every view observing it forty times.
    private func setKeyed(_ id: UUID, _ present: Bool) {
        if present, !keyed.contains(id) { keyed.insert(id) }
        if !present, keyed.contains(id) { keyed.remove(id) }
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

    /// Writes the key. Returns whether the Keychain accepted it.
    ///
    /// The `SecItemAdd` status used to be discarded, so a refused write was indistinguishable
    /// from a stored one and the UI showed "saved" for a key no request could read.
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        delete(account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
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
