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
}

private struct OllamaPullProgress: Decodable {
    let status: String
    let total: Int64?
    let completed: Int64?
}

/// Talks to the Ollama server over its local REST API (default
/// 127.0.0.1:11434) instead of shelling out to the `ollama` CLI. Ollama
/// itself is installed and launched by the user like any other Mac app —
/// Session Notes never spawns it and never needs to know where its binary
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

    func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("api/tags")
        let (data, response) = try await session.data(from: url)
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
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
        ]
        if !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["system"] = system
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
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
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 600
                    var body: [String: Any] = ["model": model, "prompt": prompt, "stream": true]
                    if !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        body["system"] = system
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw OllamaError.notReachable }
                    guard http.statusCode == 200 else {
                        throw http.statusCode == 404 ? OllamaError.modelNotFound(model) : OllamaError.badResponse
                    }

                    var full = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard let chunk = OllamaClient.streamChunk(fromLine: line) else { continue }
                        full += chunk.text
                        continuation.yield(full)
                        if chunk.done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Parses one NDJSON line from `/api/generate` streaming into its text delta
    /// and done flag. Pure, so the streaming accumulation is unit-testable.
    static func streamChunk(fromLine line: String) -> (text: String, done: Bool)? {
        guard let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        else { return nil }
        return (decoded.response, decoded.done)
    }

    /// Streams pull progress (0...1) as Ollama downloads a model, so the
    /// Settings screen can show a real progress bar instead of a spinner —
    /// no Terminal `ollama pull` command required.
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "stream": true])

        let (bytes, response) = try await session.bytes(for: request)
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
