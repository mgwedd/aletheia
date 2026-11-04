import XCTest
@testable import Aletheia

/// Times what a therapist does after a 50-minute session, on the CPU path the
/// app uses on Intel: the digest and its sections, a Fast note, the first Ask
/// and a follow-up Ask. The real app code runs every stage
/// (`DigestBuilder`, `LongSessionNote`, `LongSessionChat`) against the real
/// engine, so the calls, prompts and reply caps are the ones a user gets.
///
/// Run by `.github/workflows/bench-intel.yml`; skipped unless
/// ALETHEIA_INFERENCE_BENCH is set, and the 50-minute run also needs
/// ALETHEIA_BENCH_WORKLOAD (it takes most of an hour). Synthetic transcript only.
///
/// Inputs (environment):
/// - ALETHEIA_BENCH_GGUF: the default MedGemma 1.5 4B Q4_K_M.
/// - ALETHEIA_BENCH_BUDGETS: context budgets to run, e.g. "8192 16384" (an
///   8 GB and a 16 GB Intel Mac).
/// - ALETHEIA_BENCH_REUSE: "0" reads every prompt in full (the engine before
///   prompt-cache reuse).
/// - ALETHEIA_BENCH_RUNTIME: a label for the report (which runtime is linked).
///
/// Each stage prints one `BENCH-INFER {json}` line with `kind: "workload"`.
@MainActor
final class SessionWorkloadBenchmarkTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        try XCTSkipUnless(env["ALETHEIA_INFERENCE_BENCH"] != nil, "set ALETHEIA_INFERENCE_BENCH to run")
        try XCTSkipUnless(LlamaRuntime.isBuilt, "llama runtime not linked")
        // The test host app owns the shared index; use a private one.
        SessionSearch.index = SearchIndex()
    }

    func testFiftyMinuteSession() async throws {
        try XCTSkipUnless(env["ALETHEIA_BENCH_WORKLOAD"] != nil, "set ALETHEIA_BENCH_WORKLOAD to run")
        let gguf = URL(fileURLWithPath: try XCTUnwrap(env["ALETHEIA_BENCH_GGUF"]))
        let reuse = env["ALETHEIA_BENCH_REUSE"] != "0"
        let runtime = env["ALETHEIA_BENCH_RUNTIME"] ?? "pinned"
        let budgets = (env["ALETHEIA_BENCH_BUDGETS"] ?? "16384").split(separator: " ").compactMap { Int($0) }
        let transcript = SyntheticSession.transcript(minutes: 50)
        print("BENCH-INFO workload transcript chars=\(transcript.count) estimatedTokens=\(ContextBudget.estimatedTokens(forCharacters: transcript.count)) reuse=\(reuse) runtime=\(runtime) threads=\(InferenceCompute.cpuThreads)")
        let model = LlamaModel.medgemma15_4b

        for tokens in budgets {
            let budget = ContextBudget(tokens: tokens)
            let engine = RecordingEngine(LlamaEngine(
                modelURL: gguf, sampling: LocalLLMSampling(maxTokens: ContextBudget.replyHeadroomTokens),
                budget: budget, usesGPU: false, reusesPromptCache: reuse))
            try await engine.load()
            var service = AssistantService(
                assistant: LlamaAssistant(modelURL: gguf, budget: budget, engineOverride: engine), model: model.rawValue)
            service.budget = budget
            service.readsLongTranscripts = model.readsLongTranscripts
            let builder = DigestBuilder(queue: InferenceQueue())
            let sessionID = UUID()
            let base: [String: Any] = ["kind": "workload", "budget": tokens, "reuse": reuse, "runtime": runtime]

            func stage(_ name: String, _ body: () async throws -> String) async throws -> String {
                engine.begin(name)
                let clock = ContinuousClock()
                var text = ""
                let elapsed = try await clock.measure { text = try await body() }
                let calls = engine.calls(in: name)
                var fields = base
                fields["stage"] = name
                fields["seconds"] = elapsed.seconds
                fields["calls"] = calls.count
                fields["prompt_tokens"] = calls.map { $0.stats?.promptTokens ?? 0 }.reduce(0, +)
                fields["cached_tokens"] = calls.map(\.cached).reduce(0, +)
                fields["output_tokens"] = calls.map { $0.stats?.outputTokens ?? 0 }.reduce(0, +)
                fields["prompt_s"] = Double(calls.map { $0.stats?.promptNanos ?? 0 }.reduce(0, +)) / 1e9
                fields["output_s"] = Double(calls.map { $0.stats?.outputNanos ?? 0 }.reduce(0, +)) / 1e9
                fields["text"] = String(text.prefix(600))
                report(fields)
                return text
            }

            var digest: SessionDigest?
            _ = try await stage("digest") {
                let built = try await builder.build(transcript: transcript, service: service)
                digest = built
                return built.sessionDigest
            }
            let stored = try XCTUnwrap(digest)

            let note = try await stage("note (Fast)") {
                var last = ""
                for try await partial in LongSessionNote.stream(
                    format: .soap, transcript: transcript, effort: .fast,
                    riskPhrases: LongSessionNote.defaultRiskPhrases, service: service, builder: builder,
                    sessionID: sessionID, loadDigest: { stored }, saveDigest: { _ in },
                    live: { _, _ in }, coverage: { _ in }
                ) { last = partial }
                return last
            }
            XCTAssertFalse(note.isEmpty, "budget \(tokens): empty note")

            func ask(_ question: String, history: [ChatMessage]) async throws -> String {
                var last = ""
                for try await partial in LongSessionChat.stream(
                    transcript: transcript, history: history, question: question, effort: .fast,
                    sessionID: sessionID, service: service, builder: builder,
                    loadDigest: { stored }, saveDigest: { _ in }, live: { _, _ in }, coverage: { _ in }
                ) { last = partial }
                return last
            }
            let first = "What did the client say about her sleep, and was any risk raised?"
            let answer = try await stage("Ask (first)") { try await ask(first, history: []) }
            XCTAssertFalse(answer.isEmpty, "budget \(tokens): empty first answer")
            let followUp = "What did we agree she would try before next week?"
            let history = [
                ChatMessage(role: .user, text: first),
                ChatMessage(role: .assistant, text: answer),
                ChatMessage(role: .user, text: followUp),
            ]
            let second = try await stage("Ask (follow-up)") { try await ask(followUp, history: history) }
            XCTAssertFalse(second.isEmpty, "budget \(tokens): empty follow-up answer")
            engine.unload()
        }
    }

    /// The second of two requests that share a prefix reads only its new
    /// tokens, and writes exactly what a fresh engine writes for it.
    func testAFollowUpReadsOnlyItsNewTokensAndAnswersTheSame() async throws {
        let gguf = URL(fileURLWithPath: try XCTUnwrap(env["ALETHEIA_BENCH_GGUF"]))
        let session = SyntheticSession.transcript(minutes: 6)
        let system = "You answer questions about a therapy session transcript."
        func request(_ question: String) -> LocalLLMRequest {
            LocalLLMRequest(system: system, prompt: "Transcript:\n\(session)\n\nTherapist's question: \(question)",
                            sampling: LocalLLMSampling(maxTokens: 48, temperature: 0))
        }
        let first = request("What is the name of the client's dog?")
        let second = request("Who did the client have dinner with?")
        func engine() -> LlamaEngine {
            LlamaEngine(modelURL: gguf, sampling: LocalLLMSampling(maxTokens: 48), budget: ContextBudget(tokens: 4096),
                        usesGPU: InferenceCompute.usesGPU)
        }

        let warm = engine()
        try await warm.load()
        _ = try await warm.generate(first)
        let clock = ContinuousClock()
        var reused = ""
        let warmTime = try await clock.measure { reused = try await warm.generate(second) }
        let kept = warm.lastCachedTokens
        let read = try XCTUnwrap(warm.lastStats?.promptTokens)
        warm.unload()

        let cold = engine()
        try await cold.load()
        var fresh = ""
        let coldTime = try await clock.measure { fresh = try await cold.generate(second) }
        let total = try XCTUnwrap(cold.lastStats?.promptTokens)
        XCTAssertEqual(cold.lastCachedTokens, 0)
        cold.unload()

        // llama.cpp doesn't promise the same logits for different batch
        // shapes (13 new tokens on a cache vs the whole prompt at once), so a
        // greedy reply can part ways late, at a near-tie. A broken cache
        // (wrong positions, a missing window) changes the reply from its first
        // words, so those must match; whether all of it matched is reported.
        let reusedWords = InferenceBenchmarkTests.words(reused), freshWords = InferenceBenchmarkTests.words(fresh)
        let common = zip(reusedWords, freshWords).prefix { $0 == $1 }.count
        report(["kind": "prefix-reuse", "total_tokens": total, "kept_tokens": kept, "read_tokens": read,
                "warm_s": warmTime.seconds, "cold_s": coldTime.seconds, "same_output": reused == fresh,
                "same_words": common, "words": freshWords.count, "text": reused, "fresh": fresh])
        XCTAssertGreaterThan(kept, total / 2, "the shared transcript was read again")
        XCTAssertEqual(read, total - kept, "the follow-up read more than its new tokens")
        XCTAssertGreaterThanOrEqual(common, min(20, freshWords.count),
                                    "reusing the cache changed the answer:\n\(reused)\n---\n\(fresh)")
    }

    private func report(_ fields: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        print("BENCH-INFER \(String(decoding: data, as: UTF8.self))")
    }
}

/// Wraps the real engine and keeps each call's stats, by stage.
private final class RecordingEngine: LocalLLMEngine, @unchecked Sendable {
    struct Call {
        let stage: String
        let stats: AIRunStats?
        let cached: Int
    }

    private let inner: LlamaEngine
    private let lock = NSLock()
    private var stage = ""
    private var recorded: [Call] = []

    init(_ inner: LlamaEngine) { self.inner = inner }

    func begin(_ stage: String) { lock.withLock { self.stage = stage } }
    func calls(in stage: String) -> [Call] { lock.withLock { recorded.filter { $0.stage == stage } } }

    var state: LocalLLMEngineState { inner.state }
    func load() async throws { try await inner.load() }
    func unload() { inner.unload() }

    private func record() {
        let call = Call(stage: lock.withLock { stage }, stats: inner.lastStats, cached: inner.lastCachedTokens)
        lock.withLock { recorded.append(call) }
    }

    func generate(_ request: LocalLLMRequest) async throws -> String {
        let text = try await inner.generate(request)
        record()
        return text
    }

    func stream(_ request: LocalLLMRequest) -> AsyncThrowingStream<String, Error> {
        stream(request, onStats: nil)
    }

    func stream(
        _ request: LocalLLMRequest, onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        let source = inner.stream(request, onStats: onStats)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await partial in source { continuation.yield(partial) }
                    self.record()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A made-up 50-minute session: a line about every 20 seconds, varied enough
/// to read like speech, with a few facts to ask about (the dog Biscuit,
/// dinner with her sister, a passing risk statement and its denial, and the
/// plan for the week).
enum SyntheticSession {
    private static let client = [
        "Sleep has been uneven since the move, I fall asleep fine but wake around four and lie there thinking about work.",
        "My dog Biscuit has honestly been the best part of the week, he gets me out of the flat every morning.",
        "Work has been relentless, my manager keeps adding projects and I never feel like I finish anything properly.",
        "I had dinner with my sister Ana on Sunday and it was nice, though she asked a lot about how I am coping.",
        "I have been skipping lunch most days because there is no time, and by the evening I am exhausted and irritable.",
        "The new flat is quieter than the old one, which I thought would help, but the quiet makes my mind louder.",
        "I tried the breathing exercise twice, once on the bus and once before a meeting, and it took the edge off.",
        "My mother called again about the holidays and I felt that familiar knot in my stomach before I even answered.",
        "I keep scrolling on my phone in bed even though I know it keeps me up, it feels like the only time that is mine.",
        "On Thursday I snapped at a colleague over something small, and I felt guilty about it for the rest of the day.",
        "I went for a walk after dinner on two evenings, and those were the two nights I slept a bit better.",
        "I am still taking the sertraline, fifty milligrams in the morning, and I do not notice side effects any more.",
    ]
    private static let therapist = [
        "What do you notice in your body when you lie awake at four, and what are the first thoughts that show up?",
        "It sounds like Biscuit gives the day some structure. What would it be like to build on that morning walk?",
        "When the projects pile up, what do you tell yourself about what will happen if something is not finished?",
        "How did it feel to be asked so many questions by Ana, and what did you want her to understand?",
        "Let us slow down here. What usually happens in the hour before you go to bed on a work night?",
        "You said the quiet makes your mind louder. Can you say more about what it gets loud about?",
        "That is a real step. What made it easier to try the breathing on the bus than at home?",
        "When the knot shows up before you answer your mother, what are you bracing for?",
    ]

    static func transcript(minutes: Int) -> String {
        let lines = minutes * 3
        return (0..<lines).map { i -> String in
            let seconds = i * 20
            let stamp = String(format: "[%02d:%02d]", seconds / 60, seconds % 60)
            if i == lines * 2 / 3 {
                return "\(stamp) Call audio: Some nights I think it would be easier not to wake up at all, just for a moment, and then it passes."
            }
            if i == lines * 2 / 3 + 1 {
                return "\(stamp) You: Thank you for telling me. Do you have any plan or intent to act on that? Call audio: No, none at all, I would never do that, it is a thought that comes when I am exhausted."
            }
            if i == lines - 3 {
                return "\(stamp) You: So before next week, the plan is a walk with Biscuit after dinner on at least four evenings, and the phone stays in the kitchen after ten. Call audio: Yes, I can do that."
            }
            if i % 2 == 0 {
                let a = client[(i * 5) % client.count], b = client[(i * 7 + 3) % client.count]
                return "\(stamp) Call audio: \(a) \(b)"
            }
            let a = therapist[(i * 3) % therapist.count], b = client[(i * 11 + 1) % client.count]
            return "\(stamp) You: \(a) Call audio: \(b)"
        }.joined(separator: "\n")
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
