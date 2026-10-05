import XCTest
@testable import Aletheia

/// The local-LLM engine seam is package-free and compiled in every build, so its
/// contract — request assembly, sampling defaults, and graceful behavior when no
/// runtime is linked — is unit-tested here regardless of tier. The real llama.cpp
/// engine plugs in behind `#if canImport(llama)` at the pin step.
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

    func testComposedPromptPrependsSystemWhenPresent() {
        let req = LocalLLMRequest(system: "You are careful.", prompt: "Summarize.")
        XCTAssertEqual(req.composedPrompt, "System: You are careful.\n\nSummarize.")
    }

    func testComposedPromptOmitsEmptyOrWhitespaceSystem() {
        XCTAssertEqual(LocalLLMRequest(system: "", prompt: "Q").composedPrompt, "Q")
        XCTAssertEqual(LocalLLMRequest(system: "   \n ", prompt: "Q").composedPrompt, "Q")
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

    /// In every current build (the llama package isn't pinned yet), the factory
    /// returns a gracefully-unavailable engine rather than crashing or half-wiring.
    func testFactoryReturnsUnavailableEngineWithoutRuntime() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist.gguf")
        let engine = LocalLLMEngineFactory.make(modelURL: url)
        guard case .unavailable = engine.state else {
            return XCTFail("expected an unavailable engine without the llama runtime, got \(engine.state)")
        }
    }
}
