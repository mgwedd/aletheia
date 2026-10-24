#if canImport(llama)
import XCTest
@testable import Aletheia

/// Unload paths of the built-in model; none of these load weights.
final class LlamaUnloadTests: XCTestCase {
    private func engine(_ name: String) -> LlamaEngine {
        LlamaEngine(modelURL: URL(fileURLWithPath: "/nonexistent/\(name).gguf"), sampling: LocalLLMSampling(maxTokens: 32))
    }

    func testUnloadAllEmptiesTheCache() {
        LlamaAssistant.unloadAll()
        LlamaAssistant.cacheForTesting(engine("a"), at: URL(fileURLWithPath: "/nonexistent/a.gguf"))
        LlamaAssistant.cacheForTesting(engine("b"), at: URL(fileURLWithPath: "/nonexistent/b.gguf"))
        XCTAssertEqual(LlamaAssistant.cachedEngineCount, 2)
        LlamaAssistant.unloadAll()
        XCTAssertEqual(LlamaAssistant.cachedEngineCount, 0)
    }

    func testIdleUnloadFiresWhenNoNewRequest() {
        let e = engine("idle")
        e.idleDelay = 0.05
        e.scheduleIdleUnload()
        let waited = expectation(description: "waited")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertEqual(e.idleUnloads, 1)
    }

    func testNewRequestCancelsPendingIdleUnload() {
        let e = engine("busy")
        e.idleDelay = 0.05
        e.scheduleIdleUnload()
        e.markActive()
        let waited = expectation(description: "waited")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertEqual(e.idleUnloads, 0)
    }

    func testLlamaAssistantRequestCarriesTaskSamplingAndGrammar() {
        let assistant = LlamaAssistant(modelURL: URL(fileURLWithPath: "/nonexistent/m.gguf"))
        let soapReq = assistant.request(
            system: "sys",
            prompt: "user",
            task: .note,
            grammar: ProgressNoteFormat.soap.grammar
        )
        XCTAssertEqual(soapReq.sampling, LocalLLMSampling.forTask(.note))
        XCTAssertEqual(soapReq.grammar, ProgressNoteFormat.soap.grammar)

        let digestReq = assistant.request(system: "sys", prompt: "user", task: .digest, grammar: nil)
        XCTAssertEqual(digestReq.sampling.maxTokens, 768)
        XCTAssertNil(digestReq.grammar)

        let customCap = LlamaAssistant(modelURL: URL(fileURLWithPath: "/nonexistent/m.gguf"), maxTokens: 321)
        XCTAssertEqual(customCap.request(system: "s", prompt: "p", task: .digest).sampling.maxTokens, 321)
    }

    func testLlamaAssistantThrowsModelNotDownloadedOnGenerateAndStreamWhenFileMissing() async {
        let assistant = LlamaAssistant(modelURL: URL(fileURLWithPath: "/nonexistent/missing.gguf"))
        do {
            _ = try await assistant.generate(
                model: "m", system: "s", prompt: "p", task: .note, grammar: ProgressNoteFormat.soap.grammar
            )
            XCTFail("expected modelNotDownloaded")
        } catch {
            XCTAssertEqual(error as? LocalLLMEngineError, .modelNotDownloaded)
        }

        do {
            for try await _ in assistant.stream(
                model: "m", system: "s", prompt: "p", task: .note, grammar: ProgressNoteFormat.soap.grammar, onStats: nil
            ) {
                XCTFail("expected no tokens")
            }
            XCTFail("expected stream to throw modelNotDownloaded")
        } catch {
            XCTAssertEqual(error as? LocalLLMEngineError, .modelNotDownloaded)
        }
    }

    func testCancelledGenerateThrowsCancellationError() async {
        let e = engine("cancel")
        let task = Task {
            try await e.generate(LocalLLMRequest(prompt: "hi"))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancelled generate() to throw")
        } catch is CancellationError {
            // Expected when cancelled before/during load.
        } catch {
            // If the queue ran before cancel() landed, loadFailed on /nonexistent is also acceptable;
            // verify a pre-cancelled Task always throws CancellationError.
        }

        let preCancelled = Task { () throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await e.generate(LocalLLMRequest(prompt: "hi"))
        }
        do {
            _ = try await preCancelled.value
            XCTFail("expected pre-cancelled generate() to throw CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}

final class LlamaLoadSizeCheckTests: XCTestCase {
    private func tempModel(bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("size-\(UUID().uuidString).gguf")
        try Data(count: bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLlamaLoadRejectsWrongSizedModel() async throws {
        let url = try tempModel(bytes: 99)
        var loaderCalls = 0
        let engine = LlamaEngine(
            modelURL: url, adapterURL: nil, expectedModelBytes: 100,
            sampling: LocalLLMSampling(maxTokens: 32),
            modelLoader: { _ in loaderCalls += 1; return nil })
        do {
            try await engine.load()
            XCTFail("expected a size error")
        } catch let error as LocalLLMEngineError {
            XCTAssertTrue(error.errorDescription?.contains("damaged or incomplete") == true, "\(error)")
        }
        XCTAssertEqual(loaderCalls, 0, "a wrong-sized file must never reach the loader")
    }

    func testMissingModelReportsNotDownloaded() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).gguf")
        var loaderCalls = 0
        let engine = LlamaEngine(
            modelURL: url, adapterURL: nil, expectedModelBytes: 100,
            sampling: LocalLLMSampling(maxTokens: 32),
            modelLoader: { _ in loaderCalls += 1; return nil })
        do {
            try await engine.load()
            XCTFail("expected modelNotDownloaded")
        } catch {
            XCTAssertEqual(error as? LocalLLMEngineError, .modelNotDownloaded)
        }
        XCTAssertEqual(loaderCalls, 0)
    }

    func testRightSizedModelReachesTheLoader() async throws {
        let url = try tempModel(bytes: 100)
        var loadedURL: URL?
        let engine = LlamaEngine(
            modelURL: url, adapterURL: nil, expectedModelBytes: 100,
            sampling: LocalLLMSampling(maxTokens: 32),
            modelLoader: { loadedURL = $0; return nil })
        do {
            try await engine.load()
            XCTFail("the stub loader returns nil")
        } catch let error as LocalLLMEngineError {
            XCTAssertTrue(error.errorDescription?.contains("Couldn't load") == true, "\(error)")
        }
        XCTAssertEqual(loadedURL, url)
    }
}
#endif
