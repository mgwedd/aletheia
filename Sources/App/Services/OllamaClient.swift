import Foundation

enum OllamaError: LocalizedError {
    case notReachable
    case badResponse
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notReachable:
            return "Can't reach Ollama. Make sure the Ollama app is open (look for its icon in the menu bar)."
        case .badResponse:
            return "Ollama sent back something unexpected."
        case .modelNotFound(let name):
            return "The \"\(name)\" model isn't downloaded yet. Open Settings to download it."
        }
    }
}

private struct OllamaTagsResponse: Decodable {
    struct Model: Decodable { let name: String }
    let models: [Model]
}

private struct OllamaGenerateResponse: Decodable {
    let response: String
    let done: Bool
    // Only on the final chunk; durations are nanoseconds.
    let promptEvalCount: Int?
    let promptEvalDuration: Int?
    let evalCount: Int?
    let evalDuration: Int?

    enum CodingKeys: String, CodingKey {
        case response, done
        case promptEvalCount = "prompt_eval_count"
        case promptEvalDuration = "prompt_eval_duration"
        case evalCount = "eval_count"
        case evalDuration = "eval_duration"
    }
}

/// Remembers, per model, a hash of each 2,000-character prefix of the last
/// prompt sent (never the text), so the next request can tell how much of its
/// start Ollama probably still holds. Ollama keeps the model's working state
/// for a shared prefix, and some versions then leave it out of
/// `prompt_eval_count` (checked on a current one: it still counts the whole
/// prompt, with a near-zero `prompt_eval_duration`). Expecting only the new
/// tail is safe under either behaviour: it can't raise a false alarm.
final class PromptPrefixMemory: @unchecked Sendable {
    static let shared = PromptPrefixMemory()
    static let step = 2000
    private let lock = NSLock()
    private var last: [String: [Int]] = [:]

    /// Characters at the start of `text` that match the previous prompt for
    /// `model`, rounded down to a step; then remembers `text`.
    func sharedPrefixCharacters(model: String, text: String) -> Int {
        var hasher = Hasher()
        var hashes: [Int] = []
        var index = text.startIndex
        while let end = text.index(index, offsetBy: Self.step, limitedBy: text.endIndex), end != index {
            hasher.combine(text[index..<end])
            var snapshot = hasher
            hashes.append(snapshot.finalize())
            index = end
        }
        lock.lock()
        defer { lock.unlock() }
        let previous = last[model] ?? []
        last[model] = hashes
        var shared = 0
        while shared < min(previous.count, hashes.count), previous[shared] == hashes[shared] { shared += 1 }
        return shared * Self.step
    }
}

private struct OllamaPullProgress: Decodable {
    let status: String
    let total: Int64?
    let completed: Int64?
}

/// Talks to the Ollama server over its local REST API (default
/// 127.0.0.1:11434) instead of shelling out to the `ollama` CLI. Ollama
/// itself is installed and launched by the user like any other Mac app —
/// Aletheia never spawns it and never needs to know where its binary
/// lives, which is also what keeps the app sandbox-compatible (it only
/// needs the network-client entitlement, not permission to run arbitrary
/// executables).
final class OllamaClient: Assistant {
    private let baseURL: URL
    private let session = URLSession.shared

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func isReachable() async -> Bool {
        (try? await listModels()) != nil
    }

    /// Whether a thrown error is Ollama simply not running/listening — a
    /// connection-level `URLError` rather than an HTTP or decode failure. Used to
    /// turn URLSession's bare "Could not connect to the server" into the app's
    /// own, actionable "Can't reach Ollama…" message. Pure, so it's unit-tested.
    static func isConnectionFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .timedOut, .dnsLookupFailed, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    /// Runs a URLSession call, translating a connection-level failure into
    /// `OllamaError.notReachable` so every path shows the friendly guidance.
    private func mappingConnectionErrors<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            if Self.isConnectionFailure(error) { throw OllamaError.notReachable }
            throw error
        }
    }

    func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("api/tags")
        let (data, response) = try await mappingConnectionErrors { try await session.data(from: url) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.notReachable
        }
        let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return decoded.models.map { $0.name }
    }

    func hasModel(_ name: String) async -> Bool {
        (try? await listModels())?.contains { $0 == name || $0 == "\(name):latest" || $0.hasPrefix("\(name):") } ?? false
    }

    func generate(model: String, system: String, prompt: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // stream:false means Ollama sends nothing until the whole response
        // is ready. Summarizing a long transcript with an 8B model on a
        // MacBook Air can easily run past URLSession's 60s default request
        // timeout, so give it plenty of headroom rather than failing a slow
        // (but working) local generation.
        request.timeoutInterval = 600
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.generateBody(model: model, system: system, prompt: prompt, stream: false))

        let (data, response) = try await mappingConnectionErrors { try await session.data(for: request) }
        guard let http = response as? HTTPURLResponse else { throw OllamaError.notReachable }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 { throw OllamaError.modelNotFound(model) }
            throw OllamaError.badResponse
        }
        let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        return decoded.response
    }

    /// Real token streaming via Ollama's `stream:true` NDJSON: each line is a
    /// `{response, done}` chunk. We accumulate the deltas and yield the growing
    /// full text so callers see one uniform "text so far" shape.
    func stream(model: String, system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        stream(model: model, system: system, prompt: prompt, onStats: nil)
    }

    /// `onStats` gets the run's own numbers (tokens read and written, and how
    /// long each took) from Ollama's final chunk.
    func stream(
        model: String, system: String, prompt: String, onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        let cached = onStats == nil ? 0
            : PromptPrefixMemory.shared.sharedPrefixCharacters(model: model, text: system + "\n" + prompt)
        let expectedTokens = ContextBudget.estimatedTokens(forCharacters: max(0, system.count + prompt.count - cached))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 600
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: Self.generateBody(model: model, system: system, prompt: prompt, stream: true))

                    let (bytes, response) = try await mappingConnectionErrors { try await session.bytes(for: request) }
                    guard let http = response as? HTTPURLResponse else { throw OllamaError.notReachable }
                    guard http.statusCode == 200 else {
                        throw http.statusCode == 404 ? OllamaError.modelNotFound(model) : OllamaError.badResponse
                    }

                    var full = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let chunk = OllamaClient.streamChunk(fromLine: line, expectedPromptTokens: expectedTokens)
                        else { continue }
                        full += chunk.text
                        continuation.yield(full)
                        if chunk.done {
                            if let stats = chunk.stats { onStats?(stats) }
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The `/api/generate` request. `num_ctx` is sized to the prompt: Ollama's
    /// default window (4096 tokens unless the user changed it) silently drops
    /// the start of anything longer, so a long session's note would be written
    /// from its last few minutes, without the instructions.
    static func generateBody(model: String, system: String, prompt: String, stream: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": stream,
            "options": ["num_ctx": contextSize(forCharacters: system.count + prompt.count)],
        ]
        if !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["system"] = system
        }
        return body
    }

    /// Tokens to reserve: the prompt (English runs about 4 characters a token;
    /// 3 leaves margin) plus room for the reply, rounded up to a power of two so
    /// similar requests share a size and Ollama doesn't reload the model for
    /// each. 8K floor, 128K cap (the Llama 3 models' limit), and never above this
    /// Mac's `ContextBudget`. `AssistantService` refuses a prompt over the budget
    /// before it gets here, so the cap only guards the Mac's memory.
    static func contextSize(forCharacters characters: Int, budget: Int = ContextBudget.current.tokens) -> Int {
        let needed = ContextBudget.neededTokens(forCharacters: characters)
        var size = 8192
        while size < needed && size < 131_072 { size *= 2 }
        return min(size, budget)
    }

    /// Parses one NDJSON line from `/api/generate` streaming into its text delta,
    /// done flag and, on the final chunk, the run's stats. Pure, so the streaming
    /// accumulation is unit-testable.
    static func streamChunk(
        fromLine line: String, expectedPromptTokens: Int = 0
    ) -> (text: String, done: Bool, stats: AIRunStats?)? {
        guard let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        else { return nil }
        let stats = decoded.done
            ? AIRunStats(
                promptTokens: decoded.promptEvalCount, promptNanos: decoded.promptEvalDuration,
                outputTokens: decoded.evalCount, outputNanos: decoded.evalDuration,
                expectedPromptTokens: expectedPromptTokens)
            : nil
        return (decoded.response, decoded.done, stats)
    }

    /// Streams pull progress (0...1) as Ollama downloads a model, so the
    /// Settings screen can show a real progress bar instead of a spinner —
    /// no Terminal `ollama pull` command required.
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "stream": true])

        let (bytes, response) = try await mappingConnectionErrors { try await session.bytes(for: request) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.notReachable
        }

        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8) else { continue }
            guard let progress = try? JSONDecoder().decode(OllamaPullProgress.self, from: data) else { continue }
            if let total = progress.total, let completed = progress.completed, total > 0 {
                onProgress(Double(completed) / Double(total), progress.status)
            } else {
                onProgress(0, progress.status)
            }
        }
    }
}
