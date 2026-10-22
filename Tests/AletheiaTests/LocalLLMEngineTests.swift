import XCTest
@testable import Aletheia

/// The local-LLM engine seam is package-free and compiled in every build, so its
/// contract — request assembly, sampling defaults, and graceful behavior when no
/// runtime is linked — is unit-tested here regardless of tier. The real llama.cpp
/// engine is always compiled in since the package is now linked.
final class LocalLLMEngineTests: XCTestCase {
    // MARK: Request / sampling / grammar value types

    func testDeterministicSamplingIsGreedy() {
        let s = LocalLLMSampling.deterministic
        XCTAssertEqual(s.temperature, 0)
        XCTAssertEqual(s.maxTokens, 512)
        XCTAssertNil(s.seed)
        XCTAssertTrue(s.isGreedy)
    }

    func testPositiveTemperatureIsNotGreedy() {
        XCTAssertFalse(LocalLLMSampling(temperature: 0.7).isGreedy)
    }

    func testRequestDefaultsAreDeterministicAndGrammarless() {
        let req = LocalLLMRequest(prompt: "hi")
        XCTAssertEqual(req.sampling, .deterministic)
        XCTAssertNil(req.grammar)
    }

    func testGrammarCarriesLabelAndText() {
        let g = LocalLLMGrammar(label: "SOAP", gbnf: "root ::= \"x\"")
        XCTAssertEqual(g, LocalLLMGrammar(label: "SOAP", gbnf: "root ::= \"x\""))
        XCTAssertNotEqual(g, LocalLLMGrammar(label: "DAP", gbnf: "root ::= \"x\""))
    }

    // MARK: Unavailable engine (the production/preview and pre-pin behavior)

    func testUnavailableEngineReportsUnavailable() {
        let engine = UnavailableLocalLLMEngine(reason: "nope")
        XCTAssertEqual(engine.state, .unavailable(reason: "nope"))
        XCTAssertFalse(engine.state.isReady)
    }

    func testUnavailableEngineLoadThrows() async {
        let engine = UnavailableLocalLLMEngine()
        do {
            try await engine.load()
            XCTFail("expected load() to throw")
        } catch {
            XCTAssertTrue(error is LocalLLMEngineError)
        }
    }

    func testUnavailableEngineGenerateThrows() async {
        let engine = UnavailableLocalLLMEngine(reason: "nope")
        do {
            _ = try await engine.generate(LocalLLMRequest(prompt: "hi"))
            XCTFail("expected generate() to throw")
        } catch {
            XCTAssertEqual(error as? LocalLLMEngineError, .unavailable("nope"))
        }
    }

    func testUnavailableEngineStreamFinishesWithError() async {
        let engine = UnavailableLocalLLMEngine(reason: "nope")
        do {
            for try await _ in engine.stream(LocalLLMRequest(prompt: "hi")) {
                XCTFail("expected no tokens")
            }
            XCTFail("expected the stream to throw")
        } catch {
            XCTAssertEqual(error as? LocalLLMEngineError, .unavailable("nope"))
        }
    }

    // MARK: Factory

    /// Without the llama runtime the factory returns a gracefully-unavailable
    /// engine; with it, a real engine that hasn't loaded anything yet.
    func testFactoryMatchesRuntimeAvailability() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist.gguf")
        let engine = LocalLLMEngineFactory.make(modelURL: url)
        if LlamaRuntime.isBuilt {
            guard case .notLoaded = engine.state else {
                return XCTFail("expected a not-yet-loaded engine, got \(engine.state)")
            }
        } else {
            guard case .unavailable = engine.state else {
                return XCTFail("expected an unavailable engine without the llama runtime, got \(engine.state)")
            }
        }
    }

    // MARK: Per-task sampling & GBNF wiring

    func testTaskSamplingAppliesPerTaskCapsAndRepeatPenalty() {
        let note = LocalLLMSampling.forTask(.note)
        XCTAssertEqual(note.maxTokens, ContextBudget.replyHeadroomTokens)
        XCTAssertEqual(note.temperature, AITask.note.temperature)
        XCTAssertEqual(note.repeatPenalty, 1.1)
        XCTAssertEqual(note.repeatLastN, 64)

        let chat = LocalLLMSampling.forTask(.chat)
        XCTAssertEqual(chat.maxTokens, ContextBudget.replyHeadroomTokens)
        XCTAssertEqual(chat.temperature, AITask.chat.temperature)

        let digest = LocalLLMSampling.forTask(.digest)
        XCTAssertEqual(digest.maxTokens, 768)
        XCTAssertEqual(digest.temperature, AITask.digest.temperature)

        let compaction = LocalLLMSampling.forTask(.compaction)
        XCTAssertEqual(compaction.maxTokens, 512)
        XCTAssertEqual(compaction.temperature, AITask.compaction.temperature)

        let overridden = LocalLLMSampling.forTask(.digest, maxTokens: 128)
        XCTAssertEqual(overridden.maxTokens, 128)
    }

    func testDefaultEngineStreamWithOnStatsDelegatesToStream() async throws {
        final class BatchOnlyEngine: LocalLLMEngine {
            var state: LocalLLMEngineState { .ready }
            func load() async throws {}
            func unload() {}
            func generate(_ request: LocalLLMRequest) async throws -> String { "batch:\(request.prompt)" }
        }
        let engine = BatchOnlyEngine()
        var snapshots: [String] = []
        for try await snap in engine.stream(LocalLLMRequest(prompt: "hello"), onStats: { _ in }) {
            snapshots.append(snap)
        }
        XCTAssertEqual(snapshots, ["batch:hello"])
    }

    func testAssistantServiceForwardsFormatGrammarOnProgressNotesAndNilElsewhere() async throws {
        final class GrammarCapturingAssistant: Assistant {
            var calls: [(task: AITask, grammar: LocalLLMGrammar?)] = []
            func isReachable() async -> Bool { true }
            func listModels() async throws -> [String] { ["m"] }
            func hasModel(_ name: String) async -> Bool { true }
            func generate(model: String, system: String, prompt: String) async throws -> String { "ok" }
            func generate(
                model: String, system: String, prompt: String, task: AITask, grammar: LocalLLMGrammar?
            ) async throws -> String {
                calls.append((task, grammar))
                return "ok"
            }
            func stream(
                model: String,
                system: String,
                prompt: String,
                task: AITask,
                grammar: LocalLLMGrammar?,
                onStats: (@Sendable (AIRunStats) -> Void)?
            ) -> AsyncThrowingStream<String, Error> {
                calls.append((task, grammar))
                return AsyncThrowingStream {
                    $0.yield("ok")
                    $0.finish()
                }
            }
            func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
        }

        let spy = GrammarCapturingAssistant()
        let service = AssistantService(assistant: spy, model: "m")

        for format in [ProgressNoteFormat.soap, .dap, .birp, .girp] {
            _ = try await service.progressNote(format: format, transcript: "Client slept well.")
            XCTAssertEqual(spy.calls.last?.task, .note)
            XCTAssertEqual(spy.calls.last?.grammar, format.grammar)
            XCTAssertNotNil(spy.calls.last?.grammar)

            for try await _ in service.streamProgressNote(format: format, transcript: "Client slept well.") {}
            XCTAssertEqual(spy.calls.last?.task, .note)
            XCTAssertEqual(spy.calls.last?.grammar, format.grammar)
        }

        for try await _ in service.streamProgressNote(format: .narrative, transcript: "Client slept well.") {}
        XCTAssertEqual(spy.calls.last?.task, .note)
        XCTAssertNil(spy.calls.last?.grammar)

        _ = try await service.summarize(transcript: "Client slept well.")
        XCTAssertEqual(spy.calls.last?.task, .note)
        XCTAssertNil(spy.calls.last?.grammar)

        _ = try await service.answerAboutSession(transcript: "t", history: [], question: "q")
        XCTAssertEqual(spy.calls.last?.task, .chat)
        XCTAssertNil(spy.calls.last?.grammar)

        for try await _ in service.streamAnswerAboutSession(transcript: "t", history: [], question: "q") {}
        XCTAssertEqual(spy.calls.last?.task, .chat)
        XCTAssertNil(spy.calls.last?.grammar)

        for try await _ in service.streamAnswerAboutPatient(context: "c", history: [], question: "q") {}
        XCTAssertEqual(spy.calls.last?.task, .chat)
        XCTAssertNil(spy.calls.last?.grammar)

        for try await _ in service.streamCompaction(history: [], focus: "") {}
        XCTAssertEqual(spy.calls.last?.task, .compaction)
        XCTAssertNil(spy.calls.last?.grammar)
    }

    func testAutomaticBackendResolvesToBuiltInLlama() {
        let resolver = AssistantBackendResolver(appleIntelligenceAvailable: false)
        XCTAssertEqual(resolver.resolve(.automatic), .localLlama)
        XCTAssertEqual(resolver.resolve(.localLlama), .localLlama)
    }

    @MainActor
    func testEndToEndBuiltInAssistantFlowAcrossNotesDigestsAndChats() async throws {
        final class FakeBuiltInEngine: LocalLLMEngine, @unchecked Sendable {
            var requests: [LocalLLMRequest] = []
            var state: LocalLLMEngineState { .ready }
            func load() async throws {}
            func unload() {}
            func generate(_ request: LocalLLMRequest) async throws -> String {
                requests.append(request)
                if request.grammar == LocalToolLoop.grammar {
                    return #"{"calls":[]}"#
                }
                return "generated:\(request.grammar?.label ?? "plain")"
            }
            func stream(
                _ request: LocalLLMRequest,
                onStats: (@Sendable (AIRunStats) -> Void)?
            ) -> AsyncThrowingStream<String, Error> {
                requests.append(request)
                let reply: String
                if request.grammar == LocalToolLoop.grammar {
                    reply = #"{"calls":[]}"#
                } else if request.prompt.contains("Transcript section") {
                    reply = "Section digest [0:00–1:00]: Client discussed sleep and lithium."
                } else {
                    reply = "streamed:\(request.grammar?.label ?? "plain")"
                }
                let tokens = max(400, ContextBudget.estimatedTokens(forCharacters: request.system.count + request.prompt.count))
                return AsyncThrowingStream { continuation in
                    continuation.yield(reply)
                    onStats?(AIRunStats(
                        promptTokens: tokens,
                        promptNanos: 500_000_000,
                        outputTokens: 30,
                        outputNanos: 200_000_000
                    ))
                    continuation.finish()
                }
            }
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuiltInEndToEnd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = Store(root: tempRoot)
        let patient = try store.createPatient(name: "Alex Rivera")
        let session = try store.createSession(for: patient)
        let transcript = "[00:00] Therapist: How has sleep been?\n[00:30] Client: Better since starting lithium 300 mg."
        try store.saveTranscript(transcript, for: patient, session: session)

        let engine = FakeBuiltInEngine()
        let llamaAssistant = LlamaAssistant(
            modelURL: tempRoot.appendingPathComponent("model.gguf"),
            engineOverride: engine
        )
        var recordedStats: [AIRunStats] = []
        var service = AssistantService(assistant: llamaAssistant, model: LlamaModel.gemma4_e2b.rawValue)
        service.report = { (event: AIRunEvent) in
            if case .finished(let stats) = event {
                recordedStats.append(stats)
            }
        }

        // 1. Notes in every format (verifying GBNF grammar attachment on structured formats).
        for format in ProgressNoteFormat.allCases {
            var note = ""
            for try await partial in service.streamProgressNote(format: format, transcript: transcript) {
                note = partial
            }
            XCTAssertEqual(note, "streamed:\(format.grammar?.label ?? "plain")")
            XCTAssertEqual(engine.requests.last?.grammar, format.grammar)
        }

        // 2. Digest build.
        let builder = DigestBuilder(queue: InferenceQueue())
        let digest = try await builder.build(transcript: transcript, service: service)
        try store.saveDigest(digest, for: patient, session: session)
        XCTAssertNotNil(store.anyCurrentDigest(for: patient, session: session, transcript: transcript, model: LlamaModel.gemma4_e2b.rawValue))

        // 3. Session chat (with Normal effort tool loop).
        var sessionReply = ""
        for try await partial in LongSessionChat.stream(
            transcript: transcript,
            history: [],
            question: "What dose of lithium was mentioned?",
            effort: .normal,
            sessionID: session.id,
            service: service,
            builder: builder,
            loadDigest: { digest },
            saveDigest: { _ in },
            live: { _, _ in },
            coverage: { _ in }
        ) {
            sessionReply = partial
        }
        XCTAssertEqual(sessionReply, "streamed:plain")

        // 4. Patient-wide chat (using stored digest + Normal effort tool loop).
        let context = await store.gatherCitedPatientContext(
            for: patient,
            relevantTo: "Summarize sleep progress across sessions.",
            characterBudget: 12_000
        )
        var patientReply = ""
        for try await partial in PatientChatAnswer.stream(
            context: context,
            history: [],
            question: "Summarize sleep progress across sessions.",
            effort: .normal,
            totalBudget: 12_000,
            scope: { store.localToolScope(for: patient) },
            service: service,
            builder: builder,
            live: { _, _ in },
            onCoverage: { _ in }
        ) {
            patientReply = partial
        }
        XCTAssertEqual(patientReply, "streamed:plain")
        XCTAssertFalse(recordedStats.isEmpty)
        XCTAssertNotNil(recordedStats.last?.readTokensPerSecond)
        XCTAssertNotNil(recordedStats.last?.writeTokensPerSecond)
    }
}

