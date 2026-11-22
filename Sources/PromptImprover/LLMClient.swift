import Foundation

struct ChatMessage {
    enum Role: String { case user, assistant }
    var role: Role
    var content: String
    static func user(_ s: String) -> ChatMessage { .init(role: .user, content: s) }
    static func assistant(_ s: String) -> ChatMessage { .init(role: .assistant, content: s) }
}

enum LLMError: LocalizedError {
    case badURL(String)
    case http(Int, String)
    case api(String)
    case missingKey

    var errorDescription: String? {
        switch self {
        case .badURL(let u): return "Invalid base URL: \(u)"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(400))"
        case .api(let msg): return msg
        case .missingKey: return "No API key set for this endpoint. Open Settings (⌘,)."
        }
    }
}

/// Speaks both the OpenAI (`/chat/completions`) and Anthropic (`/messages`) wire formats.
struct LLMClient {
    let endpoint: Endpoint
    let apiKey: String

    private func request(_ path: String) throws -> URLRequest {
        let base = endpoint.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/\(path)"), let scheme = url.scheme?.lowercased() else {
            throw LLMError.badURL(endpoint.baseURL)
        }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        guard scheme == "https" || (scheme == "http" && loopback) else {
            throw LLMError.api("Refusing to send your API key over \(scheme)://. Use https (plain http is only allowed for localhost).")
        }
        var req = URLRequest(url: url, timeoutInterval: 600)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch endpoint.format {
        case .openAI:
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return req
    }

    private func redact(_ s: String) -> String {
        apiKey.count >= 8 ? s.replacingOccurrences(of: apiKey, with: "••••") : s
    }

    // MARK: Models

    func listModels() async throws -> [String] {
        let (data, resp) = try await URLSession.shared.data(
            for: try request(endpoint.format == .anthropic ? "models?limit=1000" : "models"))
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.http(http.statusCode, redact(String(decoding: data, as: UTF8.self)))
        }
        struct List: Decodable { struct M: Decodable { let id: String }; let data: [M] }
        return try JSONDecoder().decode(List.self, from: data).data.map(\.id).sorted()
    }

    // MARK: Chat (streaming)

    func stream(system: String, messages: [ChatMessage], model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try request(endpoint.format == .openAI ? "chat/completions" : "messages")
                    req.httpMethod = "POST"
                    req.httpBody = try JSONSerialization.data(withJSONObject: body(system, messages, model))

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 4000 { break } }
                        throw LLMError.http(http.statusCode, redact(text))
                    }

                    var sawData = false, stray = ""
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else {
                            if !line.hasPrefix("event:") && !line.hasPrefix(":") && stray.count < 2000 { stray += line }
                            continue
                        }
                        sawData = true
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
                        else { continue }
                        if let err = obj["error"] as? [String: Any] {
                            throw LLMError.api(err["message"] as? String ?? "Unknown API error")
                        }
                        if let chunk = delta(from: obj), !chunk.isEmpty { continuation.yield(chunk) }
                    }
                    // Some proxies answer 200 with a plain JSON error and no SSE at all.
                    if !sawData, !stray.isEmpty {
                        let obj = try? JSONSerialization.jsonObject(with: Data(stray.utf8)) as? [String: Any]
                        let msg = (obj?["error"] as? [String: Any])?["message"] as? String
                            ?? obj?["error"] as? String ?? stray
                        throw LLMError.api(redact(String(msg.prefix(400))))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(system: String, messages: [ChatMessage], model: String) async throws -> String {
        var out = ""
        for try await chunk in stream(system: system, messages: messages, model: model) { out += chunk }
        return out
    }

    private func body(_ system: String, _ messages: [ChatMessage], _ model: String) -> [String: Any] {
        let msgs = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        switch endpoint.format {
        case .openAI:
            var b: [String: Any] = [
                "model": model,
                "stream": true,
                "messages": [["role": "system", "content": system]] + msgs,
            ]
            if let effort = endpoint.reasoningEffort { b["reasoning_effort"] = effort }
            return b
        case .anthropic:
            return ["model": model, "stream": true, "max_tokens": 16000, "system": system, "messages": msgs]
        }
    }

    /// Only visible answer text — reasoning/thinking deltas are ignored on purpose.
    private func delta(from obj: [String: Any]) -> String? {
        switch endpoint.format {
        case .openAI:
            let choice = (obj["choices"] as? [[String: Any]])?.first
            return (choice?["delta"] as? [String: Any])?["content"] as? String
        case .anthropic:
            guard obj["type"] as? String == "content_block_delta",
                  let d = obj["delta"] as? [String: Any], d["type"] as? String == "text_delta" else { return nil }
            return d["text"] as? String
        }
    }
}
