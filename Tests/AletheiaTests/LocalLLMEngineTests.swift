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
}
