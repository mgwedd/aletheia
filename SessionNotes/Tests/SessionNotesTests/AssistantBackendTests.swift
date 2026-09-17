import XCTest
@testable import SessionNotes

final class AssistantBackendResolverTests: XCTestCase {
    // MARK: Automatic prefers on-device, in order

    func testAutomaticPrefersAppleIntelligenceWhenAvailable() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: true, localLlamaAvailable: true)
        XCTAssertEqual(r.resolve(.automatic), .appleIntelligence)
    }

    func testAutomaticFallsToLocalLlamaWhenNoAppleIntelligence() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: false, localLlamaAvailable: true)
        XCTAssertEqual(r.resolve(.automatic), .localLlama)
    }

    func testAutomaticFallsToOllamaWhenNothingOnDevice() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: false, localLlamaAvailable: false)
        XCTAssertEqual(r.resolve(.automatic), .ollama)
    }

    // MARK: Explicit choices are honored when available, else fall back safely

    func testExplicitAppleIntelligenceHonoredWhenAvailable() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: true, localLlamaAvailable: false)
        XCTAssertEqual(r.resolve(.appleIntelligence), .appleIntelligence)
    }

    func testExplicitAppleIntelligenceFallsBackWhenUnavailable() {
        // No on-device runtime → falls to Ollama rather than failing.
        let r = AssistantBackendResolver(appleIntelligenceAvailable: false, localLlamaAvailable: false)
        XCTAssertEqual(r.resolve(.appleIntelligence), .ollama)

        // Embedded runtime present → prefer that over Ollama.
        let withLlama = AssistantBackendResolver(appleIntelligenceAvailable: false, localLlamaAvailable: true)
        XCTAssertEqual(withLlama.resolve(.appleIntelligence), .localLlama)
    }

    func testExplicitLocalLlamaFallsBackWhenUnavailable() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: false, localLlamaAvailable: false)
        XCTAssertEqual(r.resolve(.localLlama), .ollama)
    }

    func testExplicitOllamaAlwaysResolvesToOllama() {
        let r = AssistantBackendResolver(appleIntelligenceAvailable: true, localLlamaAvailable: true)
        XCTAssertEqual(r.resolve(.ollama), .ollama)
    }

    // MARK: Enum surface used by the settings picker

    func testAllBackendsAreSelectableAndDescribed() {
        for backend in AssistantBackend.allCases {
            XCTAssertFalse(backend.displayName.isEmpty)
            XCTAssertFalse(backend.summary.isEmpty)
        }
        // Round-trips through its raw value (how it's persisted).
        for backend in AssistantBackend.allCases {
            XCTAssertEqual(AssistantBackend(rawValue: backend.rawValue), backend)
        }
    }
}
