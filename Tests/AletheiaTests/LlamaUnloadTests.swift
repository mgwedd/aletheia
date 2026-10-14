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
}
#endif
