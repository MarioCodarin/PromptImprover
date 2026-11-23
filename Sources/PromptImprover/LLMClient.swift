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
    case truncated

    var errorDescription: String? {
        switch self {
        case .badURL(let u): return "Invalid base URL: \(u)"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(400))"
        case .api(let msg): return msg
        case .missingKey: return "No API key set for this endpoint. Open Settings (⌘,)."
        case .truncated: return "The model's reply was cut off before it finished. Try again, or pick a model with a larger output limit."
        }
    }

    /// Worth another attempt: rate limits, gateway hiccups, overload. A 400 or 401 never is.
    var isTransient: Bool {
        if case .http(let code, _) = self {
            return [408, 409, 429, 500, 502, 503, 504, 529].contains(code)
        }
        if case .api(let msg) = self {
            let m = msg.lowercased()
            return m.contains("overloaded") || m.contains("rate limit") || m.contains("try again")
        }
        return false
    }
}

/// Speaks both the OpenAI-style (`/chat/completions`) and Anthropic (`/messages`) wire formats.
///
/// Two things here are load-bearing for output quality rather than plumbing:
/// - JSON stages (diagnose, verify, tests) ask for JSON mode and fall back cleanly when a gateway
///   rejects the parameter, instead of losing the call.
/// - Transient failures retry with backoff, but only while nothing has been streamed yet, so a retry
///   can never duplicate half a prompt on screen.
/// Token accounting, accumulated across every call on a client.
///
/// Cost is the second half of "is this configuration sane": a Deep run is five or six calls, and
/// without this the only way to know what it cost is the provider's dashboard tomorrow.
final class UsageTracker {
    private let lock = NSLock()
    private var _input = 0, _output = 0, _cached = 0, _cacheWrites = 0

    var inputTokens: Int { lock.withLock { _input } }
    var outputTokens: Int { lock.withLock { _output } }
    var cachedTokens: Int { lock.withLock { _cached } }
    /// Anthropic cache writes, billed above the input rate. Zero on the chat-completions format.
    var cacheWriteTokens: Int { lock.withLock { _cacheWrites } }

    private var lastInput = 0
    private var lastOutput = 0
    private var lastCached = 0
    private var lastWrites = 0

    /// Called once per request. Anthropic reports cumulative totals per message, so the deltas
    /// have to be measured against the start of *that* message, not the whole run.
    func beginCall() {
        lock.withLock {
            lastInput = 0
            lastOutput = 0
            lastCached = 0
            lastWrites = 0
        }
    }

    func observe(input: Int, output: Int, cached: Int, writes: Int = 0) {
        guard input > 0 || output > 0 else { return }
        lock.withLock {
            _input += max(0, input - lastInput)
            _output += max(0, output - lastOutput)
            // Summed, not maxed: reporting the largest single call as the run's cached total
            // misstates what the run spent.
            _cached += max(0, cached - lastCached)
            _cacheWrites += max(0, writes - lastWrites)
            lastCached = max(lastCached, cached)
            lastWrites = max(lastWrites, writes)
            lastInput = max(lastInput, input)
            lastOutput = max(lastOutput, output)
        }
    }

    /// USD, given dollars per million tokens. Returns nil when pricing is unknown.
    ///
    /// Cached input bills at a fraction of the fresh rate, so it is priced separately rather than
    /// ignored: a run that reuses a 2k-token prompt looked free when it was merely cheap.
    func cost(inputPerM: Double?, outputPerM: Double?, cachedPerM: Double? = nil,
              readRatio: Double = 0.5) -> Double? {
        guard let i = inputPerM, let o = outputPerM else { return nil }
        // The default discount is the wire format's, not one provider's: Anthropic bills cache
        // reads at 0.1x and writes at 1.25x, the chat-completions format bills cached input at
        // 0.5x and has no write tier.
        let cachedRate = cachedPerM ?? i * readRatio
        let writeRate = i * 1.25
        // `inputTokens` already includes cache reads and writes, so the fresh remainder is what is
        // left after both are priced at their own rates.
        let writes = cacheWriteTokens
        let reads = cachedTokens
        let fresh = max(0, inputTokens - reads - writes)
        return (Double(fresh) * i
                + Double(reads) * cachedRate
                + Double(writes) * writeRate
                + Double(outputTokens) * o) / 1_000_000
    }

    var summary: String {
        let cached = cachedTokens > 0 ? " (\(cachedTokens) cached)" : ""
        return "\(inputTokens) in\(cached) / \(outputTokens) out"
    }
}

struct LLMClient {
    let endpoint: Endpoint
    let apiKey: String
    /// Shared across the whole pipeline, so one run reports one total.
    let usage = UsageTracker()

    /// Makes every subsequent request fail at the transport. Used by the `--vm` probe to test the
    /// error paths of the state machine without waiting for a real outage.
    final class Poison: @unchecked Sendable {
        private let lock = NSLock()
        private var dead = false
        var isDead: Bool { lock.lock(); defer { lock.unlock() }; return dead }
        func kill() { lock.lock(); dead = true; lock.unlock() }
    }
    let poison = Poison()

    /// Parameters this endpoint has already rejected. Shared across the whole pipeline, so a
    /// locked-down gateway costs one 400 per parameter per run instead of one per stage.
    final class Rejected: @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String> = []
        func contains(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return names.contains(name) }
        func add(_ name: String) { lock.lock(); names.insert(name); lock.unlock() }
    }
    let rejected = Rejected()

    /// Tuning for one call. Nil means "let the server decide".
    struct Options {
        var temperature: Double?
        var maxTokens: Int?
        var jsonMode = false
        /// Sending `stream_options` is the only way [OI] gateways report usage on a stream, but not
        /// every gateway accepts it. Cleared by the 400 fallback like any other optional parameter.
        var streamOptions = true
        /// Mirrors the endpoint's configured effort; cleared if the gateway rejects the parameter.
        var reasoningEffort: String?
        static let `default` = Options()
        static func json(temperature: Double = 0) -> Options { .init(temperature: temperature, jsonMode: true) }
    }

    private func request(_ path: String) throws -> URLRequest {
        // The `--vm` probe kills the transport to exercise the error paths on demand.
        if poison.isDead { throw URLError(.cannotConnectToHost) }
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

    func stream(system: String,
                messages: [ChatMessage],
                model: String,
                options: Options = .default) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runStream(system: system, messages: messages, model: model,
                                        options: options) { chunk in
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(system: String,
                  messages: [ChatMessage],
                  model: String,
                  options: Options = .default) async throws -> String {
        var out = ""
        for try await chunk in stream(system: system, messages: messages, model: model, options: options) {
            out += chunk
        }
        return out
    }

    // MARK: - Streaming with retry and parameter fallback

    private func runStream(system: String,
                           messages: [ChatMessage],
                           model: String,
                           options: Options,
                           yield: (String) -> Void) async throws {
        // The endpoint's configured effort is an option, not a second fallback inside `body()`.
        // Reading it there made the 400 fallback below unreachable: clearing the option left the
        // parameter in the request, so a gateway that rejects `reasoning_effort` rejected every
        // stage of every run until the user cleared the field by hand.
        var opts = options
        if opts.reasoningEffort == nil { opts.reasoningEffort = endpoint.reasoningEffort }
        // Start from what this endpoint has already told us it does not accept.
        if rejected.contains("stream_options") { opts.streamOptions = false }
        if rejected.contains("response_format") { opts.jsonMode = false }
        if rejected.contains("temperature") { opts.temperature = nil }
        if rejected.contains("max_tokens") { opts.maxTokens = nil }
        if rejected.contains("reasoning_effort") { opts.reasoningEffort = nil }
        var attempt = 0
        // Counted separately from `attempt`: a parameter fallback is not a transient failure and
        // must not consume the retries meant for a 503.
        var transientCount = 0
        let delays: [Double] = [1, 3, 8]

        while true {
            attempt += 1
            var yieldedAnything = false
            do {
                try await streamOnce(system: system, messages: messages, model: model, options: opts) { chunk in
                    yieldedAnything = true
                    yield(chunk)
                }
                return
            } catch {
                let err = error as? LLMError ?? .api(error.localizedDescription)

                // A gateway that rejects one optional parameter should cost a retry, not the run.
                if case .http(400, let body) = err {
                    let lower = body.lowercased()
                    if opts.jsonMode, lower.contains("response_format") {
                        opts.jsonMode = false
                        rejected.add("response_format")
                        continue
                    }
                    if opts.temperature != nil, lower.contains("temperature") {
                        opts.temperature = nil
                        rejected.add("temperature")
                        continue
                    }
                    // On the Anthropic wire format max_tokens is required, so clearing it just
                    // falls back to the client default — a bigger number the gateway is more
                    // likely to reject. There is nothing to drop here.
                    if endpoint.format != .anthropic, opts.maxTokens != nil,
                       lower.contains("max_tokens") || lower.contains("max_completion_tokens") {
                        opts.maxTokens = nil
                        rejected.add("max_tokens")
                        continue
                    }
                    if opts.streamOptions, lower.contains("stream_options") {
                        opts.streamOptions = false
                        rejected.add("stream_options")
                        continue
                    }
                    if opts.reasoningEffort != nil, lower.contains("reasoning_effort") || lower.contains("reasoning") {
                        opts.reasoningEffort = nil
                        rejected.add("reasoning_effort")
                        continue
                    }
                }

                guard !yieldedAnything, transientCount < delays.count, err.isTransient, !Task.isCancelled else { throw err }
                // Count transient failures separately from parameter fallbacks: a gateway that
                // rejected two optional parameters must not eat the retries meant for a 503.
                transientCount += 1
                let base = delays[transientCount - 1]
                let jitter = Double.random(in: 0...0.4) * base
                try await Task.sleep(nanoseconds: UInt64((base + jitter) * 1_000_000_000))
            }
        }
    }

    private func streamOnce(system: String,
                            messages: [ChatMessage],
                            model: String,
                            options: Options,
                            yield: (String) -> Void) async throws {
        var req = try request(endpoint.format == .openAI ? "chat/completions" : "messages")
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body(system, messages, model, options))
        usage.beginCall()

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
            // Record usage before any throw: the tokens spent on a truncated call were still spent.
            recordUsage(obj)
            if let stop = stopReason(from: obj) {
                // Anthropic reports max_tokens here; the chat-completions format uses finish_reason "length".
                if stop == "max_tokens" || stop == "length" { throw LLMError.truncated }
            }
            if let chunk = delta(from: obj), !chunk.isEmpty { yield(chunk) }
        }
        // Some proxies answer 200 with a plain JSON error and no SSE at all.
        if !sawData, !stray.isEmpty {
            let obj = try? JSONSerialization.jsonObject(with: Data(stray.utf8)) as? [String: Any]
            let msg = (obj?["error"] as? [String: Any])?["message"] as? String
                ?? obj?["error"] as? String ?? stray
            throw LLMError.api(redact(String(msg.prefix(400))))
        }
    }

    private func body(_ system: String, _ messages: [ChatMessage], _ model: String, _ o: Options) -> [String: Any] {
        let msgs = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        switch endpoint.format {
        case .openAI:
            var b: [String: Any] = [
                "model": model,
                "stream": true,
                "messages": [["role": "system", "content": system]] + msgs,
            ]
            // Without this the provider omits usage entirely on a streamed reply. Omitted on the
            // retry if the gateway rejects the parameter.
            if o.streamOptions { b["stream_options"] = ["include_usage": true] }
            if let effort = o.reasoningEffort { b["reasoning_effort"] = effort }
            if let t = o.temperature { b["temperature"] = t }
            if let m = o.maxTokens { b["max_tokens"] = m }
            if o.jsonMode { b["response_format"] = ["type": "json_object"] }
            return b
        case .anthropic:
            var b: [String: Any] = ["model": model, "stream": true,
                                    "max_tokens": o.maxTokens ?? 16000,
                                    "system": system, "messages": msgs]
            if let t = o.temperature { b["temperature"] = t }
            return b
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

    /// [OI] sends a final chunk with `usage`; Anthropic sends it on `message_start` and `message_delta`.
    /// Anthropic reports `input_tokens` exclusive of cache reads and cache writes, while the
    /// chat-completions format includes both in `prompt_tokens`. Summing the three is what makes
    /// the number mean the same thing on both wire formats.
    static func anthropicInput(_ u: [String: Any]) -> Int {
        func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        return n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens")
    }

    private func recordUsage(_ obj: [String: Any]) {
        // Anthropic nests the input counts inside `message` on message_start; only message_delta
        // carries a top-level `usage`, and that one has output tokens. Reading only the top level
        // reported every Anthropic run as zero input tokens.
        if let message = obj["message"] as? [String: Any],
           let nested = message["usage"] as? [String: Any] {
            usage.observe(input: Self.anthropicInput(nested),
                          output: (nested["output_tokens"] as? NSNumber)?.intValue ?? 0,
                          cached: (nested["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0,
                          writes: (nested["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0)
            return
        }
        guard let u = obj["usage"] as? [String: Any] else { return }
        let input = (u["prompt_tokens"] as? NSNumber)?.intValue
            ?? (u["input_tokens"] as? NSNumber)?.intValue ?? 0
        let output = (u["completion_tokens"] as? NSNumber)?.intValue
            ?? (u["output_tokens"] as? NSNumber)?.intValue ?? 0
        let cached = ((u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? NSNumber)?.intValue
            ?? (u["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
        usage.observe(input: input, output: output, cached: cached)
    }

    private func stopReason(from obj: [String: Any]) -> String? {
        switch endpoint.format {
        case .openAI:
            let choice = (obj["choices"] as? [[String: Any]])?.first
            return choice?["finish_reason"] as? String
        case .anthropic:
            guard obj["type"] as? String == "message_delta",
                  let d = obj["delta"] as? [String: Any] else { return nil }
            return d["stop_reason"] as? String
        }
    }
}
