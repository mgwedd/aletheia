#if DEBUG
import Foundation

/// Debug-only LLM evaluation (driven by scripts/eval-llm.sh):
///   --harness-eval <transcript.txt> [--question TEXT] [--model NAME] [--budget TOKENS] [--out <dir>]
/// Runs the app's real paths on the transcript through `AssistantService` and
/// the local Ollama client: a progress note, the session digest, and one
/// session-chat question. Prints each output with its coverage, timings and the
/// fixed seed/model/num_ctx; with --out, also writes `report.txt` and
/// `report.json` there. Temperature 0 and a fixed seed, so reruns match.
/// The transcript is PHI: the script never writes outside the terminal or an
/// out-of-repo directory.
struct HarnessEvalArgs: Equatable {
    static let seed = 42
    static let defaultQuestion = "What were the main topics discussed, and were there any risk concerns?"

    var transcript: URL
    var question = defaultQuestion
    var model: String?
    var budgetTokens: Int?
    var out: URL?

    /// nil when `--harness-eval` is absent or has no file.
    static func parse(_ argv: [String]) -> HarnessEvalArgs? {
        func value(_ flag: String) -> String? {
            guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
            return argv[i + 1]
        }
        guard let file = value("--harness-eval") else { return nil }
        var args = HarnessEvalArgs(transcript: URL(fileURLWithPath: file))
        if let q = value("--question"), !q.isEmpty { args.question = q }
        args.model = value("--model")
        args.budgetTokens = value("--budget").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        args.out = value("--out").map { URL(fileURLWithPath: $0, isDirectory: true) }
        return args
    }
}

/// One evaluated stage (note, digest, chat) and how to print it.
struct EvalStage {
    /// One model call: what we estimated sending and what Ollama reported.
    struct Call { var estimatedTokens: Int; var stats: AIRunStats? }

    var name: String
    var output: String
    var error: String?
    var wallSeconds: Double
    var calls: [Call]
    /// What was read, worded from the transcript and the calls made.
    var coverage: String

    var promptTokens: Int { calls.compactMap(\.stats?.promptTokens).reduce(0, +) }
    var estimatedTokens: Int { calls.map(\.estimatedTokens).reduce(0, +) }
    var truncated: Bool { calls.contains { $0.stats?.possiblyTruncated == true } }
    /// Requests always carry this Mac's budget as `num_ctx` (see `OllamaClient.generateBody`).
    var numCtx: Int? { calls.isEmpty ? nil : ContextBudget.current.tokens }
    /// Cold prefill speed: only calls with no shared prompt prefix. Ollama counts a cached
    /// prefix in prompt_eval_count but barely spends time on it, which inflates the rate.
    var prefillTPS: Double? { Self.prefill(calls.filter { $0.stats?.reusedPrefix == false }) }
    /// Calls that reused a cached prefix: not a measure of how fast this Mac reads.
    var warmPrefillTPS: Double? { Self.prefill(calls.filter { $0.stats?.reusedPrefix == true }) }
    var decodeTPS: Double? { Self.rate(calls.compactMap(\.stats?.outputTokens), calls.compactMap(\.stats?.outputNanos)) }

    private static func prefill(_ calls: [Call]) -> Double? {
        rate(calls.compactMap(\.stats?.promptTokens), calls.compactMap(\.stats?.promptNanos))
    }

    private static func rate(_ tokens: [Int], _ nanos: [Int]) -> Double? {
        let n = nanos.reduce(0, +)
        return tokens.isEmpty || n <= 0 ? nil : Double(tokens.reduce(0, +)) / (Double(n) / 1e9)
    }

    func text() -> String {
        func tps(_ v: Double?) -> String { v.map { String(format: "%.1f tok/s", $0) } ?? "n/a" }
        let reported = calls.contains { $0.stats?.promptTokens != nil } ? String(promptTokens) : "n/a"
        var lines = ["== \(name) ==", error.map { "ERROR: \($0)" } ?? output, "", "coverage: \(coverage)"]
        lines.append("prompt tokens: \(reported) (Ollama prompt_eval_count) vs \(estimatedTokens) estimated, "
            + "\(calls.count) call(s); " + (truncated ? "TRIPWIRE FIRED: possibly truncated" : "tripwire clear"))
        var timing = String(format: "timing: wall %.1fs, prefill %@ (cold)", wallSeconds, tps(prefillTPS))
        if let warm = warmPrefillTPS { timing += ", prefill " + tps(warm) + " (cache-warm, inflated by prefix cache)" }
        lines.append(timing + ", decode " + tps(decodeTPS))
        if let numCtx { lines.append("num_ctx: \(numCtx)") }
        return lines.joined(separator: "\n")
    }

    var json: [String: Any] {
        var d: [String: Any] = [
            "name": name, "output": output, "coverage": coverage, "wallSeconds": wallSeconds,
            "estimatedPromptTokens": estimatedTokens, "calls": calls.count, "possiblyTruncated": truncated,
        ]
        if let error { d["error"] = error }
        if calls.contains(where: { $0.stats?.promptTokens != nil }) { d["promptEvalCount"] = promptTokens }
        if let numCtx { d["numCtx"] = numCtx }
        if let prefillTPS { d["prefillTokensPerSecond"] = prefillTPS }
        if let warmPrefillTPS { d["prefillCacheWarmTokensPerSecond"] = warmPrefillTPS }
        if let decodeTPS { d["decodeTokensPerSecond"] = decodeTPS }
        return d
    }
}

enum EvalReport {
    /// `numCtx` is what requests actually carry; it differs from `budget` under --budget,
    /// which only changes what the app treats as fitting.
    static func header(model: String, budget: Int, numCtx: Int = ContextBudget.current.tokens, transcriptChars: Int) -> String {
        let ctx = budget == numCtx ? "" : " (--budget override; requests send num_ctx \(numCtx))"
        return "Aletheia LLM eval: model \(model), seed \(HarnessEvalArgs.seed), temperature 0, "
            + "context budget \(budget) tokens\(ctx), transcript \(transcriptChars) chars "
            + "(~\(ContextBudget.estimatedTokens(forCharacters: transcriptChars)) tokens estimated)"
    }

    /// The label for what a successful run read, from the transcript itself.
    static func coverage(transcript: String, sections: Int? = nil) -> String {
        var last: Int?
        for line in transcript.split(separator: "\n") {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let parts = line[line.index(after: line.startIndex)..<close].split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 || parts.count == 3 else { continue }
            last = max(last ?? 0, parts.reduce(0) { $0 * 60 + $1 })
        }
        let span = last.map { " (\(TranscriptTimeline.durationLabel($0)))" } ?? ""
        return sections.map { "Read: \($0) section digests, merged\(span)" } ?? "Read: full transcript\(span)"
    }

    static func text(header: String, stages: [EvalStage]) -> String {
        ([header, ""] + stages.map { $0.text() + "\n" }).joined(separator: "\n")
    }

    static func json(header: String, stages: [EvalStage]) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: ["header": header, "seed": HarnessEvalArgs.seed, "stages": stages.map(\.json)],
            options: [.prettyPrinted, .sortedKeys])
    }
}

/// Thread-safe collector for `AssistantService.report` events.
private final class EvalRunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [EvalStage.Call] = []
    private var pending = 0
    func record(_ event: AIRunEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .reading(let tokens): pending = tokens
        case .finished(let stats): calls.append(.init(estimatedTokens: pending, stats: stats))
        }
    }
    func take() -> [EvalStage.Call] {
        lock.lock(); defer { lock.unlock() }
        defer { calls = [] }
        return calls
    }
}

@MainActor
enum HarnessEval {
    static func runIfRequested(argv: [String]) -> Bool {
        guard let args = HarnessEvalArgs.parse(argv) else { return false }
        // A windowless app can otherwise be terminated while it waits on the model.
        ProcessInfo.processInfo.disableAutomaticTermination("eval")
        ProcessInfo.processInfo.disableSuddenTermination()
        Task { @MainActor in exit(await run(args)) }
        return true
    }

    private static func run(_ args: HarnessEvalArgs) async -> Int32 {
        guard let transcript = try? String(contentsOf: args.transcript, encoding: .utf8) else {
            print("error: can't read \(args.transcript.lastPathComponent)")
            return 1
        }
        let settings = AppSettings.shared
        let model = args.model ?? settings.ollamaModelName
        let client = OllamaClient(baseURL: settings.ollamaBaseURL)
        guard await client.hasModel(model) else {
            print("error: \(OllamaError.modelNotFound(model).localizedDescription)")
            return 1
        }
        // Reproducible: greedy decoding and a fixed seed for every call below.
        OllamaClient.extraOptions = ["temperature": 0, "seed": HarnessEvalArgs.seed]
        let log = EvalRunLog()
        var service = AssistantService(assistant: client, model: model)
        if let t = args.budgetTokens { service.budget = ContextBudget(tokens: t) }
        service.report = { log.record($0) }
        let svc = service

        let header = EvalReport.header(model: model, budget: svc.budget.tokens, transcriptChars: transcript.count)
        print(header + "\n")
        var stages: [EvalStage] = []
        func stage(_ name: String, coverage: String, _ work: () async throws -> String) async {
            _ = log.take()
            let start = Date()
            var out = "", err: String?
            do { out = try await work() } catch { err = error.localizedDescription }
            let s = EvalStage(name: name, output: out, error: err, wallSeconds: Date().timeIntervalSince(start),
                              calls: log.take(), coverage: err == nil ? coverage : "Not read: \(err ?? "")")
            stages.append(s)
            print(s.text() + "\n")
        }

        await stage("Progress note (narrative)", coverage: EvalReport.coverage(transcript: transcript)) {
            try await last(svc.streamProgressNote(format: .narrative, transcript: transcript))
        }
        let sections = TranscriptSections.split(transcript).count
        await stage("Session digest", coverage: EvalReport.coverage(transcript: transcript, sections: sections)) {
            try await DigestBuilder(queue: InferenceQueue()).build(transcript: transcript, service: svc).sessionDigest
        }
        await stage("Chat answer: \(args.question)", coverage: EvalReport.coverage(transcript: transcript)) {
            try await last(svc.streamAnswerAboutSession(transcript: transcript, history: [], question: args.question))
        }

        if let out = args.out {
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try? EvalReport.text(header: header, stages: stages)
                .write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            try? EvalReport.json(header: header, stages: stages)?.write(to: out.appendingPathComponent("report.json"))
        }
        return stages.contains { $0.error != nil } ? 1 : 0
    }

    private static func last(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await snapshot in stream { text = snapshot }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
