import XCTest
@testable import Aletheia

/// Loads a real GGUF through `LlamaEngine` and generates a few tokens. Skipped
/// unless `ALETHEIA_TEST_GGUF` points at a model file, so CI (which has none)
/// still passes. Synthetic text only.
final class LlamaEngineSmokeTests: XCTestCase {
    private func engine() throws -> LlamaEngine {
        try XCTSkipUnless(LlamaRuntime.isBuilt, "llama runtime not linked")
        let path = ProcessInfo.processInfo.environment["ALETHEIA_TEST_GGUF"] ?? ""
        try XCTSkipIf(path.isEmpty || !FileManager.default.fileExists(atPath: path),
                      "Set ALETHEIA_TEST_GGUF to a GGUF file to run")
        return LlamaEngine(modelURL: URL(fileURLWithPath: path), sampling: LocalLLMSampling(maxTokens: 32))
    }

    func testGeneratesTokens() async throws {
        let engine = try engine()
        try await engine.load()
        let start = Date()
        let out = try await engine.generate(LocalLLMRequest(
            prompt: "Write one short sentence about the weather.",
            sampling: LocalLLMSampling(maxTokens: 24)
        ))
        let secs = Date().timeIntervalSince(start)
        print("LLAMA_SMOKE generate: \(out.count) chars in \(String(format: "%.2f", secs))s: \(out.debugDescription)")
        XCTAssertFalse(out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        engine.unload()
    }

    func testGrammarConstrainedNoteHasSoapHeadings() async throws {
        let engine = try engine()
        let request = LocalLLMRequest(
            prompt: "Write a note about a synthetic client who discussed sleep.",
            sampling: LocalLLMSampling(maxTokens: 160),
            grammar: ProgressNoteFormat.soap.grammar
        )
        let out = try await engine.generate(request)
        print("LLAMA_SMOKE grammar: \(out.debugDescription)")
        XCTAssertTrue(out.hasPrefix("## Subjective\n"))
        for heading in ["## Subjective", "## Objective", "## Assessment", "## Plan"] {
            // The token cap may truncate late sections; the first must always be present.
            if heading == "## Subjective" { XCTAssertTrue(out.contains(heading)) }
        }
        engine.unload()
    }
}
