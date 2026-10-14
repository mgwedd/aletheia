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
            system: "Answer in one sentence.",
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
        engine.unload()
    }
}

/// Long-session measurement. Skipped unless `ALETHEIA_TEST_GGUF` and
/// `ALETHEIA_TEST_LONG_PROMPTS` (a directory of synthetic `prompt-*.txt` files) are set.
final class LlamaEngineLongContextTests: XCTestCase {
    private func peakFootprintGB() -> Double {
        var info = rusage_info_v4()
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return Double(info.ri_lifetime_max_phys_footprint) / 1e9
    }

    private func peakRSSGB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1e9  // bytes on macOS
    }

    func testLongPrompts() async throws {
        try XCTSkipUnless(LlamaRuntime.isBuilt, "llama runtime not linked")
        let env = ProcessInfo.processInfo.environment
        let gguf = env["ALETHEIA_TEST_GGUF"] ?? ""
        let dir = env["ALETHEIA_TEST_LONG_PROMPTS"] ?? ""
        try XCTSkipIf(gguf.isEmpty || dir.isEmpty, "Set ALETHEIA_TEST_GGUF and ALETHEIA_TEST_LONG_PROMPTS")

        let engine = LlamaEngine(modelURL: URL(fileURLWithPath: gguf), sampling: LocalLLMSampling(maxTokens: 256),
                                 // Past this Mac's own budget, to compare with the Ollama runs of the same files.
                                 budget: ContextBudget(tokens: 131_072))
        try await engine.load()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasPrefix("prompt-") }.sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
        for file in files {
            let prompt = try String(contentsOfFile: dir + "/" + file, encoding: .utf8)
            let start = Date()
            var first: Date?
            var yields = 0
            var out = ""
            for try await soFar in engine.stream(LocalLLMRequest(prompt: prompt, sampling: LocalLLMSampling(maxTokens: 256))) {
                if first == nil { first = Date() }
                yields += 1
                out = soFar
            }
            let end = Date()
            let prefill = (first ?? end).timeIntervalSince(start)
            let decode = end.timeIntervalSince(first ?? end)
            print(String(format: "LLAMA_BENCH %@ prompt_tokens=%d n_ctx=%d prefill_s=%.1f prefill_tps=%.0f decode_tokens=%d decode_tps=%.1f wall_s=%.1f peak_footprint_GB=%.1f peak_rss_GB=%.1f",
                         file, engine.lastPromptTokens, engine.contextTokens, prefill,
                         Double(engine.lastPromptTokens) / prefill, yields, Double(max(0, yields - 1)) / decode,
                         end.timeIntervalSince(start), peakFootprintGB(), peakRSSGB()))
            print("LLAMA_BENCH_OUT \(file): \(out.debugDescription)")
            XCTAssertTrue(out.contains("Biscuit"), "\(file): the reply should use the line at the start of the transcript")
        }
        engine.unload()
    }
}
