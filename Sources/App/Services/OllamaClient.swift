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

/// What a request is for. Notes, digests and factual chat want the same
/// answer every time, so they run cool; this is the one place that says how cool.
enum AITask {
    case note, digest, chat, compaction

    var temperature: Double {
        switch self {
        case .note, .digest, .compaction: return 0.2
        case .chat: return 0.3
        }
    }
}

/// Tracks which Ollama model this app has loaded and whether a request is
/// running, so a session opening can warm the model at most once in a while
/// and a lock can unload whatever is loaded without being handed a client.
final class OllamaResidency: @unchecked Sendable {
    static let shared = OllamaResidency()
    /// Don't warm again within this long of the last request or warm-up.
    static let warmInterval: TimeInterval = 5 * 60
    private let lock = NSLock()
    struct Entry: Hashable { let baseURL: URL; let model: String }
    /// Every model used or warmed since the last unload, so a lock frees them all.
    private var loaded: Set<Entry> = []
    private var last: Entry?
    private var inFlight = 0
    private var lastActivity: Date?
    private var locked = false
    /// Bumped on every unload, so a warm-up that finishes after one is ignored.
    private var generation = 0
    /// Warm-ups sent and not yet answered, so parallel callers don't each POST.
    private var warming: Set<Entry> = []
    /// What the last unload freed, for the next unlock to load again.
    private var resume: Set<Entry> = []

    struct WarmClaim { let entry: Entry; let generation: Int }

    func began(baseURL: URL, model: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let entry = Entry(baseURL: baseURL, model: model)
        loaded.insert(entry)
        last = entry
        inFlight += 1
        lastActivity = now
    }

    func ended(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        inFlight = max(0, inFlight - 1)
        lastActivity = now
    }

    /// While locked nothing may be warmed (e.g. a session restored behind the lock screen).
    func setLocked(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        locked = value
    }

    /// A claim unless locked, a request is running, this model at this URL is already
    /// being warmed, or it ran or warmed recently. Counts nothing until `warmed`.
    func claimWarmUp(baseURL: URL, model: String, now: Date = Date()) -> WarmClaim? {
        lock.lock(); defer { lock.unlock() }
        let entry = Entry(baseURL: baseURL, model: model)
        if locked || inFlight > 0 || warming.contains(entry) { return nil }
        if last == entry, let at = lastActivity, now.timeIntervalSince(at) < Self.warmInterval { return nil }
        warming.insert(entry)
        return WarmClaim(entry: entry, generation: generation)
    }

    /// A warm-up succeeded: the model is resident and the debounce starts. Ignored if
    /// an unload or lock happened since the claim.
    func warmed(_ claim: WarmClaim, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard claim.generation == generation else { return }
        warming.remove(claim.entry)
        guard !locked else { return }
        loaded.insert(claim.entry)
        last = claim.entry
        lastActivity = now
    }

    /// A warm-up failed: nothing resident, nothing debounced.
    func warmFailed(_ claim: WarmClaim) {
        lock.lock(); defer { lock.unlock() }
        if claim.generation == generation { warming.remove(claim.entry) }
    }

    /// The models to unload, forgetting them (a later warm-up must reload).
    func takeLoaded() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        defer { loaded = []; last = nil; lastActivity = nil; warming = []; generation += 1 }
        resume.formUnion(loaded)
        return Array(loaded)
    }

    /// The models an unload freed since the last call: what to load again after an unlock.
    func takeResume() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        defer { resume = [] }
        return Array(resume)
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
        try await generate(model: model, system: system, prompt: prompt, task: .chat)
    }

    func generate(model: String, system: String, prompt: String, task: AITask) async throws -> String {
        OllamaResidency.shared.began(baseURL: baseURL, model: model)
        defer { OllamaResidency.shared.ended() }
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
            withJSONObject: Self.generateBody(model: model, system: system, prompt: prompt, stream: false, task: task))

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
        stream(model: model, system: system, prompt: prompt, task: .chat, onStats: nil)
    }

    func stream(
        model: String, system: String, prompt: String, onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        stream(model: model, system: system, prompt: prompt, task: .chat, onStats: onStats)
    }

    /// `onStats` gets the run's own numbers (tokens read and written, and how
    /// long each took) from Ollama's final chunk.
    func stream(
        model: String, system: String, prompt: String, task: AITask, onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        let cached = onStats == nil ? 0
            : PromptPrefixMemory.shared.sharedPrefixCharacters(model: model, text: system + "\n" + prompt)
        let expectedTokens = ContextBudget.estimatedTokens(forCharacters: max(0, system.count + prompt.count - cached))
        return AsyncThrowingStream { continuation in
            OllamaResidency.shared.began(baseURL: baseURL, model: model)
            let job = Task {
                defer { OllamaResidency.shared.ended() }
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 600
                    request.httpBody = try JSONSerialization.data(
                        withJSONObject: Self.generateBody(model: model, system: system, prompt: prompt, stream: true, task: task))

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
            continuation.onTermination = { _ in job.cancel() }
        }
    }

    /// How long Ollama keeps the model loaded after a request. Long enough to
    /// span a therapist's gaps between notes; short enough that a quit app doesn't
    /// pin ~5 GB forever. Locking the app unloads it at once (`unloadLoaded`).
    static let keepAlive = "30m"

    /// The `/api/generate` request. `num_ctx` is always this Mac's budget, never
    /// sized to the prompt: a different `num_ctx` makes Ollama reload the model
    /// (a multi-second stall) and drops its prompt-prefix cache. The default
    /// window (4096 tokens) would silently drop the start of a long prompt;
    /// `AssistantService` refuses anything over the budget before it gets here.
    static func generateBody(
        model: String, system: String, prompt: String, stream: Bool,
        task: AITask = .chat, contextTokens: Int = ContextBudget.current.tokens
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": stream,
            "keep_alive": keepAlive,
            "options": ["num_ctx": contextTokens, "temperature": task.temperature],
        ]
        if !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["system"] = system
        }
        return body
    }

    /// Loads the model with the same `num_ctx` and `keep_alive` real requests use
    /// (an empty prompt only loads it), so the first real call doesn't pay the load.
    static func warmUpBody(model: String, contextTokens: Int = ContextBudget.current.tokens) -> [String: Any] {
        ["model": model, "prompt": "", "stream": false, "keep_alive": keepAlive,
         "options": ["num_ctx": contextTokens]]
    }

    /// Asks Ollama to free the model now.
    static func unloadBody(model: String) -> [String: Any] {
        ["model": model, "prompt": "", "stream": false, "keep_alive": 0]
    }

    private static func fireAndForget(_ baseURL: URL, _ body: [String: Any], completion: (@Sendable (Bool) -> Void)? = nil) {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = data
        Task.detached {
            let response = (try? await URLSession.shared.data(for: request))?.1
            completion?((response as? HTTPURLResponse)?.statusCode == 200)
        }
    }

    func warmUp(model: String) {
        guard !model.isEmpty,
              let claim = OllamaResidency.shared.claimWarmUp(baseURL: baseURL, model: model) else { return }
        Self.fireAndForget(baseURL, Self.warmUpBody(model: model)) { ok in
            if ok { OllamaResidency.shared.warmed(claim) } else { OllamaResidency.shared.warmFailed(claim) }
        }
    }

    /// Unloads every model this app used since the last unload. Called when the app locks; never
    /// waits on Ollama and ignores any failure.
    static func unloadLoaded() {
        for entry in OllamaResidency.shared.takeLoaded() {
            fireAndForget(entry.baseURL, unloadBody(model: entry.model))
        }
    }

    /// Loads again whatever the last lock unloaded; nothing if nothing was resident.
    static func warmUpResumed() {
        for entry in OllamaResidency.shared.takeResume() {
            OllamaClient(baseURL: entry.baseURL).warmUp(model: entry.model)
        }
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
