import Foundation

public enum APIFormat: String, Codable, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    public var id: String { rawValue }
}

public struct Endpoint: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name: String
    public var baseURL: String
    public var format: APIFormat = .openAI
    public var models: [String] = []
    public var selectedModel: String?
    /// nil = don't send. Otherwise sent as `reasoning_effort` (OpenAI format only).
    public var reasoningEffort: String?

    public static let refuseless = Endpoint(
        name: "Refuseless",
        baseURL: "https://api.refuseless.com/v1",
        format: .openAI,
        models: ["glm-5.3-abliterated", "glm-5.3-flash-abliterated", "kimi-k3.1-pro",
                 "deepseek-v4.1-flash-fast", "minimax-m3.1-flash"],
        selectedModel: "glm-5.3-abliterated"
    )

    public init(id: UUID = UUID(), name: String, baseURL: String, format: APIFormat = .openAI,
         models: [String] = [], selectedModel: String? = nil, reasoningEffort: String? = nil) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.format = format
        self.models = models; self.selectedModel = selectedModel; self.reasoningEffort = reasoningEffort
    }

    /// Tolerant decoding: missing or unknown fields fall back to defaults instead of failing the whole list.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Endpoint"
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        format = (try? c.decodeIfPresent(APIFormat.self, forKey: .format)) ?? .openAI
        models = (try? c.decodeIfPresent([String].self, forKey: .models)) ?? []
        selectedModel = try? c.decodeIfPresent(String.self, forKey: .selectedModel)
        reasoningEffort = try? c.decodeIfPresent(String.self, forKey: .reasoningEffort)
    }

    public static let presets: [Endpoint] = [
        .refuseless,
        Endpoint(name: "OpenAI", baseURL: "https://api.openai.com/v1"),
        Endpoint(name: "Anthropic", baseURL: "https://api.anthropic.com/v1", format: .anthropic),
        Endpoint(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1"),
        Endpoint(name: "Ollama (local)", baseURL: "http://localhost:11434/v1"),
    ]
}

